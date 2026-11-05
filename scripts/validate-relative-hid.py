#!/usr/bin/env python3
"""Build and run a bounded, cross-process ScreenFence edge validation."""
from datetime import datetime
from pathlib import Path
import argparse
import json
import os
import shutil
import signal
import subprocess
import sys
import time


PROJECT = Path(__file__).resolve().parent.parent
VALIDATION_WORK = PROJECT / "work" / "ScreenFence-validation"
BUILD_WORK = PROJECT / "work" / "ScreenFence-build"
TOOLS = PROJECT / "ValidationTools"
MOTION_WINDOW = 10.0
CLEANUP_GRACE = 0.75


def read_report(path):
    try:
        value = json.loads(path.read_text())
        return value if isinstance(value, dict) else {}
    except (OSError, ValueError):
        return {}


def complete_pass(report):
    """A partial or failed run never qualifies for the cleanup-only grace."""
    return report.get("checksComplete") is True and report.get("passed") is True


def running_screenfence():
    result = subprocess.run(
        ["pgrep", "-x", "ScreenFence"], capture_output=True, text=True, check=False
    )
    return result.stdout.strip() if result.returncode == 0 else ""


def prepare(prepared_app=None):
    if not shutil.which("xcrun") or not shutil.which("swift"):
        raise RuntimeError("需要安装 Xcode 或包含 Swift 的开发工具。")
    VALIDATION_WORK.mkdir(parents=True, exist_ok=True)
    helper = VALIDATION_WORK / "RelativeHIDInput"
    driver = VALIDATION_WORK / "AppEdgeValidation"
    log_path = VALIDATION_WORK / "prepare.log"
    commands = []
    if prepared_app is None:
        commands.append([
            "swift", "build", "--package-path", str(PROJECT),
            "--scratch-path", str(BUILD_WORK),
            "--configuration", "debug", "--product", "ScreenFence",
        ])
    commands += [
        [
            "xcrun", "clang", str(TOOLS / "RelativeHIDInput.c"),
            "-framework", "ApplicationServices", "-framework", "IOKit",
            "-o", str(helper),
        ],
        [
            "xcrun", "swiftc", str(TOOLS / "AppEdgeValidation.swift"),
            "-o", str(driver),
        ],
    ]
    print("正在编译 App 和独立验证工具；此阶段不会移动鼠标。", flush=True)
    with log_path.open("w") as log:
        for command in commands:
            result = subprocess.run(
                command, cwd=PROJECT, stdout=log, stderr=subprocess.STDOUT,
                timeout=180, check=False,
            )
            if result.returncode:
                raise RuntimeError("编译失败，记录位于 {}".format(log_path))
    if prepared_app is None:
        result = subprocess.run(
            [
                "swift", "build", "--package-path", str(PROJECT),
                "--scratch-path", str(BUILD_WORK),
                "--configuration", "debug", "--show-bin-path",
            ],
            capture_output=True, text=True, timeout=30, check=True,
        )
        lines = [line.strip() for line in result.stdout.splitlines() if line.strip()]
        if not lines:
            raise RuntimeError("Swift 未返回编译产物目录。")
        app = Path(lines[-1]) / "ScreenFence"
    else:
        app = prepared_app
    if not all(path.is_file() for path in (helper, driver, app)):
        raise RuntimeError("编译产物不完整，请查看 {}".format(log_path))
    return app, helper, driver


def signal_owned(process, sig, use_group, warnings):
    """Signal only a subprocess created by this invocation."""
    if process is None or process.poll() is not None:
        return
    sent = False
    if use_group:
        try:
            # start_new_session made this group ours. Refuse any changed group.
            if os.getpgid(process.pid) == process.pid:
                os.killpg(process.pid, sig)
                sent = True
        except ProcessLookupError:
            return
        except (PermissionError, OSError) as error:
            warnings.append("进程组信号失败，改用已跟踪 PID：{}".format(error))
    if not sent and process.poll() is None:
        try:
            process.send_signal(sig)
        except ProcessLookupError:
            pass
        except (PermissionError, OSError) as error:
            warnings.append("无法向已跟踪 PID {} 发送信号：{}".format(process.pid, error))


def stop_owned(process, use_group, warnings):
    if process is None or process.poll() is not None:
        return True
    signal_owned(process, signal.SIGTERM, use_group, warnings)
    try:
        process.wait(timeout=0.25)
        return True
    except subprocess.TimeoutExpired:
        signal_owned(process, signal.SIGKILL, use_group, warnings)
        try:
            process.wait(timeout=0.25)
        except subprocess.TimeoutExpired:
            warnings.append("已跟踪 PID {} 在清理期限内未退出。".format(process.pid))
    return process.poll() is not None


def stop_reported_helpers(report, driver, warnings):
    """Stop a recorded helper only while it is still this driver's child."""
    if driver is None:
        return
    for value in report.get("activeHelperPIDs", []):
        if not isinstance(value, int) or value <= 1:
            continue
        try:
            result = subprocess.run(
                ["ps", "-p", str(value), "-o", "ppid="],
                capture_output=True, text=True, timeout=0.2, check=False,
            )
            if result.returncode == 0 and result.stdout.strip() == str(driver.pid):
                try:
                    os.kill(value, signal.SIGTERM)
                except ProcessLookupError:
                    pass
                except (PermissionError, OSError) as error:
                    warnings.append("无法停止已跟踪输入子进程 {}：{}".format(value, error))
        except (OSError, subprocess.TimeoutExpired) as error:
            warnings.append("读取输入子进程状态失败：{}".format(error))


def execute(args, app_path, helper, driver):
    if running_screenfence():
        print("已有屏界正在运行。请先退出，再执行验证。", file=sys.stderr)
        return 77

    preflight = subprocess.run(
        [str(helper), "--preflight"], capture_output=True, text=True,
        timeout=2, check=False,
    )
    try:
        authorization = json.loads(preflight.stdout)
    except ValueError:
        authorization = {}
    if preflight.returncode != 0 or authorization.get("ready") is not True:
        print(
            "验证需要当前终端已有辅助功能和输入事件权限，且所有鼠标按钮已松开。\n"
            "本工具未请求或修改任何权限。当前状态：{}".format(preflight.stdout.strip()),
            file=sys.stderr,
        )
        return 77

    print(
        "\n接下来会启动同源开发版屏界，并短暂把鼠标移到主屏的边缘，"
        "检查持续顶边、沿边移动及第一次向内回拉。\n"
        "测试期间请勿移动鼠标、触摸板或按鼠标按钮。实际移动最多 10 秒，"
        "随后约 2 秒清理。测试只控制本次启动的进程。\n"
        "发现真实鼠标输入干扰会中止；最后会退出测试 App 并恢复原鼠标位置。",
        flush=True,
    )
    if not args.yes:
        if not sys.stdin.isatty():
            print("非交互运行需显式传入 --yes，确认现在可以短暂移动鼠标。", file=sys.stderr)
            return 64
        try:
            input("准备好并松开鼠标后，按 Enter 开始：")
        except (EOFError, KeyboardInterrupt):
            print("\n已取消，未移动鼠标。")
            return 130

    if running_screenfence():
        print("准备期间检测到另一个屏界进程，未开始测试。", file=sys.stderr)
        return 77
    if args.report.exists():
        print("报告文件已存在，请选择新的 --report 路径：{}".format(args.report), file=sys.stderr)
        return 73
    args.report.parent.mkdir(parents=True, exist_ok=True)
    where = subprocess.run(
        [str(helper), "--where"], capture_output=True, text=True,
        timeout=1, check=False,
    )
    original = where.stdout.split()
    if where.returncode != 0 or len(original) != 2:
        print("无法保存测试前的鼠标位置，未开始测试。", file=sys.stderr)
        return 1

    app = None
    check = None
    output = ""
    errors = ""
    warnings = []
    deadline_reached = False
    cleanup_grace_used = False
    timed_out_before_checks = False
    interrupted = False
    driver_returncode = None
    app_stopped = False
    driver_stopped = False
    restored = False
    started = time.monotonic()
    target_log_path = VALIDATION_WORK / "target.log"
    target_log = target_log_path.open("w")
    print("验证开始；请等待“清理完成”后再操作鼠标。", flush=True)
    try:
        app = subprocess.Popen(
            [str(app_path)], stdin=subprocess.DEVNULL,
            stdout=target_log, stderr=subprocess.STDOUT, start_new_session=True,
        )
        command = [
            str(driver), str(app.pid), str(args.report), str(helper),
            "--axis", args.axis, "--trials", str(args.trials),
        ]
        if not args.quick:
            command.append("--countdown")
        check = subprocess.Popen(
            command, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
            stderr=subprocess.PIPE, text=True, start_new_session=True,
        )
        try:
            output, errors = check.communicate(
                timeout=max(0.1, MOTION_WINDOW - (time.monotonic() - started))
            )
        except subprocess.TimeoutExpired:
            deadline_reached = True
            snapshot = read_report(args.report)
            if complete_pass(snapshot):
                cleanup_grace_used = True
                try:
                    output, errors = check.communicate(timeout=CLEANUP_GRACE)
                except subprocess.TimeoutExpired:
                    warnings.append("App 检查已通过，但驱动仍在清理；已执行外层进程清理。")
            else:
                timed_out_before_checks = True
                warnings.append("完整检查未在移动期限内完成，保留部分报告并停止测试。")
        except KeyboardInterrupt:
            interrupted = True
            warnings.append("用户中断了验证，已进入清理。")
    except (OSError, subprocess.SubprocessError) as error:
        warnings.append("启动或运行验证失败：{}".format(error))
    finally:
        snapshot = read_report(args.report)
        stop_reported_helpers(snapshot, check, warnings)
        driver_stopped = stop_owned(check, True, warnings)
        if check is not None:
            driver_returncode = check.poll()
            if driver_stopped:
                try:
                    output, errors = check.communicate(timeout=0.25)
                except (subprocess.TimeoutExpired, OSError):
                    pass
        app_stopped = stop_owned(app, False, warnings)
        target_log.close()
        # The owning App must be gone before restoring the original pointer.
        if app_stopped:
            try:
                restoration = subprocess.run(
                    [str(helper), "--restore"] + original,
                    capture_output=True, text=True, timeout=1, check=False,
                )
                restored = restoration.returncode == 0
                if not restored:
                    warnings.append("鼠标位置恢复失败：{}".format(restoration.stderr.strip()))
            except (OSError, subprocess.TimeoutExpired) as error:
                warnings.append("鼠标位置恢复未完成：{}".format(error))
        else:
            warnings.append("测试 App 尚未退出，未在锁定仍可能生效时移动鼠标。")

    elapsed = time.monotonic() - started
    (VALIDATION_WORK / "driver.log").write_text(output + errors)
    if output:
        print(output, end="")
    if errors:
        print(errors, end="", file=sys.stderr)
    report = read_report(args.report)
    report.setdefault("passed", False)
    report.setdefault("checksComplete", False)
    cleanup_ok = app_stopped and driver_stopped and restored
    driver_exit_accepted = driver_returncode == 0 or (
        deadline_reached and cleanup_grace_used and complete_pass(report)
    )
    report["harness"] = {
        "deadlineReached": deadline_reached,
        "cleanupGraceUsed": cleanup_grace_used,
        "timedOutBeforeChecksCompleted": timed_out_before_checks,
        "interrupted": interrupted,
        "driverReturnCode": driver_returncode,
        "driverExitAccepted": driver_exit_accepted,
        "appStopped": app_stopped,
        "driverStopped": driver_stopped,
        "pointerRestored": restored,
        "cleanupSucceeded": cleanup_ok,
        "elapsedSeconds": round(elapsed, 3),
        "warnings": warnings,
        "targetLog": str(target_log_path),
    }
    args.report.write_text(json.dumps(report, ensure_ascii=False, indent=2))
    for warning in warnings:
        print("清理记录：{}".format(warning), file=sys.stderr)
    print(
        "清理完成：App 已停止={}，鼠标位置已恢复={}，耗时 {:.2f} 秒。\n报告：{}".format(
            app_stopped, restored, elapsed, args.report
        ),
        flush=True,
    )
    if interrupted:
        return 130
    if (report.get("passed") is True and cleanup_ok and driver_exit_accepted
            and not timed_out_before_checks):
        return 0
    if driver_returncode == 77:
        return 77
    return 1


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--axis", choices=["right", "bottom", "all"], default="all")
    parser.add_argument("--trials", type=int, choices=range(1, 4), default=2)
    parser.add_argument("--quick", dest="quick", action="store_true", default=True)
    parser.add_argument("--countdown", dest="quick", action="store_false")
    parser.add_argument("--yes", action="store_true", help="确认现在可以执行短时鼠标移动")
    parser.add_argument("--report", type=Path)
    parser.add_argument("--app", type=Path, help="可选：验证此同源 App 可执行文件")
    parser.add_argument("--prepare-only", action="store_true", help="只编译，不查询输入或移动鼠标")
    args = parser.parse_args()
    if running_screenfence():
        print("已有屏界正在运行。请先退出；本工具不会代为结束现有进程。", file=sys.stderr)
        return 77
    try:
        prepared_app = args.app.expanduser().resolve() if args.app else None
        if prepared_app is not None:
            if not prepared_app.is_file():
                raise RuntimeError("--app 指向的可执行文件不存在。")
        app, helper, driver = prepare(prepared_app)
        if args.prepare_only:
            print("编译检查完成，未查询输入或移动鼠标。\n工具目录：{}".format(VALIDATION_WORK))
            return 0
        if args.report is None:
            stamp = datetime.now().strftime("%Y%m%d-%H%M%S-%f")
            args.report = VALIDATION_WORK / ("relative-hid-{}-{}.json".format(args.axis, stamp))
        else:
            args.report = args.report.expanduser().resolve()
        return execute(args, app, helper, driver)
    except KeyboardInterrupt:
        print("\n已取消。", file=sys.stderr)
        return 130
    except (OSError, RuntimeError, subprocess.SubprocessError) as error:
        print("验证未完成：{}".format(error), file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
