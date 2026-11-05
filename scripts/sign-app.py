#!/usr/bin/env python3
"""Sign ScreenFence with one persistent, certificate-pinned local identity."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import secrets
import shlex
import subprocess
import sys
import tempfile
from datetime import datetime, timezone


BUNDLE_ID = "com.miaopasi.screenfence"
COMMON_NAME = "ScreenFence Local Code Signing"
PROJECT = Path(__file__).resolve().parent.parent
WORK = PROJECT / "work"
STORE = Path.home() / "Library" / "Application Support" / "ScreenFence" / "Signing"
METADATA = STORE / "identity.json"
KEYCHAIN = STORE / "ScreenFence Signing.keychain-db"
PASSWORD = STORE / "keychain-password"
CERTIFICATE = STORE / "certificate.der"
PROJECT_PIN = PROJECT / "signing-identity.json"
PRIVATE_VALUES = []


class SigningError(Exception):
    pass


def redact(text):
    for value in PRIVATE_VALUES:
        if value:
            text = text.replace(value, "<redacted>")
    return text


def run(command, label, *, environment=None, input_data=None, timeout=30):
    try:
        result = subprocess.run(
            command, input=input_data, capture_output=True, text=True,
            env=environment, timeout=timeout, check=False,
        )
    except subprocess.TimeoutExpired:
        raise SigningError(label + "超时；请检查是否有系统钥匙串提示。") from None
    except OSError as error:
        raise SigningError(label + "失败：" + str(error)) from None
    if result.returncode:
        detail = redact((result.stderr or result.stdout).strip())
        raise SigningError("{}失败（{}）：{}".format(label, result.returncode, detail))
    return result


def write_private(path, data):
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(descriptor, "wb") as handle:
        handle.write(data)


def keychain_search_list():
    result = run(["security", "list-keychains", "-d", "user"], "读取钥匙串搜索列表")
    return shlex.split(result.stdout)


def remove_new_keychain_from_search_list(previous):
    current = keychain_search_list()
    own_path = str(KEYCHAIN)
    if own_path not in previous and own_path in current:
        # Remove only our new entry; preserve other concurrent changes.
        remaining = [path for path in current if path != own_path]
        run(["security", "list-keychains", "-d", "user", "-s"] + remaining,
            "还原用户钥匙串搜索列表")


def require_owner_only(path):
    if path.is_symlink():
        raise SigningError("签名存储不能是符号链接：" + str(path))
    stat = path.stat()
    if stat.st_uid != os.getuid() or stat.st_mode & 0o077:
        raise SigningError("签名存储应仅当前用户可访问：" + str(path))


def read_project_pin():
    if not PROJECT_PIN.exists():
        return None
    if PROJECT_PIN.is_symlink():
        raise SigningError("项目签名配置不能是符号链接。")
    try:
        pin = json.loads(PROJECT_PIN.read_text())
    except (OSError, ValueError) as error:
        raise SigningError("无法读取项目签名配置：" + str(error)) from None
    if (pin.get("bundleIdentifier") != BUNDLE_ID or
            not re.fullmatch(r"[A-F0-9]{40}", pin.get("certificateSHA1", ""))):
        raise SigningError("项目签名配置无效。")
    return pin


def pin_project(metadata):
    existing = read_project_pin()
    if existing is not None:
        if existing["certificateSHA1"] != metadata["certificateSHA1"]:
            raise SigningError("本机签名身份与项目固定证书不同，已停止；不会替换身份。")
        return
    # Public certificate metadata only. No private key or password is copied
    # into the source project or deliverables.
    pin = {
        "schemaVersion": 1, "bundleIdentifier": BUNDLE_ID,
        "certificateCommonName": metadata["certificateCommonName"],
        "certificateSHA1": metadata["certificateSHA1"],
    }
    write_private(PROJECT_PIN, (json.dumps(pin, indent=2) + "\n").encode())


def load_identity(private=False):
    if not METADATA.is_file():
        raise SigningError("持久签名尚未配置，请先运行 scripts/sign-app.py --setup。")
    require_owner_only(STORE)
    require_owner_only(METADATA)
    try:
        metadata = json.loads(METADATA.read_text())
    except (OSError, ValueError) as error:
        raise SigningError("无法读取签名身份：" + str(error)) from None
    fingerprint = metadata.get("certificateSHA1", "")
    if metadata.get("bundleIdentifier") != BUNDLE_ID or not re.fullmatch(r"[A-F0-9]{40}", fingerprint):
        raise SigningError("签名身份配置无效，未重新生成证书或退回临时签名。")
    if not CERTIFICATE.is_file():
        raise SigningError("持久签名证书缺失，请恢复原签名存储，不要生成同名新证书。")
    if hashlib.sha1(CERTIFICATE.read_bytes()).hexdigest().upper() != fingerprint:
        raise SigningError("证书与固定身份不匹配，已停止签名。")
    pin = read_project_pin()
    if pin is not None and pin["certificateSHA1"] != fingerprint:
        raise SigningError("本机证书与项目固定身份不同，已停止签名。")
    if private:
        if not KEYCHAIN.is_file() or not PASSWORD.is_file():
            raise SigningError("原签名私钥或解锁文件缺失；已停止，未退回临时签名。")
        require_owner_only(KEYCHAIN)
        require_owner_only(PASSWORD)
    return metadata


def requirement(metadata):
    return 'identifier "{}" and certificate leaf = H"{}"'.format(
        BUNDLE_ID, metadata["certificateSHA1"]
    )


def setup():
    if METADATA.exists():
        metadata = load_identity(private=True)
        pin_project(metadata)
        return metadata, False
    if read_project_pin() is not None:
        raise SigningError("项目已有固定证书，但本机原签名存储缺失。请恢复原存储，未创建新身份。")
    if any(path.exists() for path in (KEYCHAIN, PASSWORD, CERTIFICATE)):
        raise SigningError("发现未完成的签名存储。请检查并恢复它，工具不会静默更换身份。")
    if STORE.is_symlink():
        raise SigningError("签名存储不能是符号链接：" + str(STORE))
    if STORE.exists() and (not STORE.is_dir() or STORE.stat().st_uid != os.getuid()):
        raise SigningError("签名存储必须是当前用户拥有的目录：" + str(STORE))
    STORE.mkdir(parents=True, mode=0o700, exist_ok=True)
    os.chmod(STORE, 0o700)
    require_owner_only(STORE)
    WORK.mkdir(parents=True, exist_ok=True)
    keychain_password = secrets.token_urlsafe(36)
    transport_password = secrets.token_urlsafe(36)
    PRIVATE_VALUES.extend([keychain_password, transport_password])
    previous_search = keychain_search_list()
    created_keychain = False
    try:
        with tempfile.TemporaryDirectory(prefix=".screenfence-signing-", dir=WORK) as temporary:
            temporary = Path(temporary)
            configuration = temporary / "certificate.cnf"
            configuration.write_text("""
[req]
prompt = no
distinguished_name = subject
x509_extensions = signing_extensions
[subject]
CN = ScreenFence Local Code Signing
O = ScreenFence Local Development
[signing_extensions]
basicConstraints = critical, CA:FALSE
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
subjectKeyIdentifier = hash
""".lstrip())
            private_key = temporary / "transport-key.pem"
            public_cert = temporary / "certificate.pem"
            transport = temporary / "identity.p12"
            environment = os.environ.copy()
            environment["SCREENFENCE_PROVISION_PASSWORD"] = transport_password
            # The private key is encrypted even while in the temporary folder.
            run([
                "/usr/bin/openssl", "req", "-new", "-x509", "-newkey", "rsa:3072",
                "-sha256", "-days", "3650", "-config", str(configuration),
                "-passout", "env:SCREENFENCE_PROVISION_PASSWORD",
                "-keyout", str(private_key), "-out", str(public_cert),
            ], "生成屏界专用签名身份", environment=environment, timeout=60)
            run([
                "/usr/bin/openssl", "pkcs12", "-export",
                "-inkey", str(private_key), "-in", str(public_cert),
                "-passin", "env:SCREENFENCE_PROVISION_PASSWORD",
                "-passout", "env:SCREENFENCE_PROVISION_PASSWORD",
                "-name", COMMON_NAME, "-out", str(transport),
            ], "准备加密身份传输", environment=environment)
            der = temporary / "certificate.der"
            run([
                "/usr/bin/openssl", "x509", "-in", str(public_cert),
                "-outform", "DER", "-out", str(der),
            ], "读取公开证书")
            fingerprint = hashlib.sha1(der.read_bytes()).hexdigest().upper()
            write_private(PASSWORD, keychain_password.encode())
            run([
                "security", "create-keychain", "-p", keychain_password, str(KEYCHAIN)
            ], "创建屏界专用钥匙串")
            created_keychain = True
            os.chmod(KEYCHAIN, 0o600)
            run([
                "security", "set-keychain-settings", "-l", "-u", "-t", "21600",
                str(KEYCHAIN),
            ], "配置专用钥匙串")
            run([
                "security", "unlock-keychain", "-p", keychain_password, str(KEYCHAIN)
            ], "解锁专用钥匙串")
            run([
                "security", "import", str(transport), "-k", str(KEYCHAIN),
                "-P", transport_password, "-x", "-T", "/usr/bin/codesign",
            ], "导入专用签名私钥")
            # This keychain contains only the key we just generated. Existing
            # login-keychain keys and their access controls are never changed.
            run([
                "security", "set-key-partition-list",
                "-S", "apple-tool:,apple:", "-s",
                "-k", keychain_password, str(KEYCHAIN),
            ], "允许系统签名工具使用专用私钥")
            write_private(CERTIFICATE, der.read_bytes())
            metadata = {
                "schemaVersion": 1,
                "bundleIdentifier": BUNDLE_ID,
                "certificateCommonName": COMMON_NAME,
                "certificateSHA1": fingerprint,
                "createdAt": datetime.now(timezone.utc).isoformat(),
            }
            write_private(METADATA, (json.dumps(metadata, indent=2) + "\n").encode())
    finally:
        if created_keychain:
            remove_new_keychain_from_search_list(previous_search)
    metadata = load_identity(private=True)
    pin_project(metadata)
    return metadata, True


def unlock(metadata):
    password = PASSWORD.read_text()
    PRIVATE_VALUES.append(password)
    run(["security", "unlock-keychain", "-p", password, str(KEYCHAIN)],
        "解锁屏界签名身份")
    identities = run(
        ["security", "find-identity", "-p", "codesigning", str(KEYCHAIN)],
        "检查专用签名身份",
    ).stdout
    # Self-signed identities need not be globally trusted. Do not use -v,
    # which hides otherwise usable self-signed code-signing identities.
    if metadata["certificateSHA1"] not in identities.upper():
        raise SigningError("找不到原签名私钥，已停止；不会创建新证书或临时签名。")


def check_bundle(path):
    info_path = path / "Contents" / "Info.plist"
    if not path.is_dir() or path.suffix.lower() != ".app" or not info_path.is_file():
        raise SigningError("签名目标必须是包含 Info.plist 的屏界 App。")
    with info_path.open("rb") as handle:
        identifier = plistlib.load(handle).get("CFBundleIdentifier")
    if identifier != BUNDLE_ID:
        raise SigningError("App 标识与屏界固定标识不符，已停止签名。")


def verify(path, metadata):
    run([
        "codesign", "--verify", "--deep", "--strict",
        "--test-requirement", "=" + requirement(metadata), str(path),
    ], "验证稳定签名")
    details = run(["codesign", "-d", "-r-", str(path)], "读取签名要求")
    text = details.stdout + details.stderr
    designated = next((line for line in text.splitlines() if line.startswith("designated =>")), "")
    normalize = lambda value: "".join(value.lower().split())
    actual = designated.removeprefix("designated =>").strip()
    if not designated or normalize(actual) != normalize(requirement(metadata)):
        raise SigningError("签名没有固定到原证书，已停止交付。")
    return designated


def main():
    os.umask(0o077)
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app", nargs="?", type=Path)
    parser.add_argument("--setup", action="store_true")
    parser.add_argument("--info", action="store_true")
    parser.add_argument("--verify", action="store_true")
    args = parser.parse_args()
    if args.setup:
        metadata, created = setup()
        print("{}持久签名身份：{}".format("已创建" if created else "已复用",
                                        metadata["certificateSHA1"]))
        return 0
    metadata = load_identity(private=not args.verify and not args.info)
    if args.info:
        print(json.dumps({
            **metadata, "designatedRequirement": requirement(metadata),
            "keychain": str(KEYCHAIN), "storage": str(STORE),
        }, ensure_ascii=False, indent=2))
        return 0
    if args.app is None:
        parser.error("请提供待签名 App，或使用 --setup / --info。")
    if read_project_pin() is None:
        raise SigningError("项目尚未固定签名证书，请先运行 --setup。")
    path = args.app.expanduser().resolve()
    if not path.exists():
        raise SigningError("待签名对象不存在：" + str(path))
    check_bundle(path)
    if not args.verify:
        unlock(metadata)
        run([
            "codesign", "--force", "--sign", metadata["certificateSHA1"],
            "--keychain", str(KEYCHAIN), "--identifier", BUNDLE_ID,
            "--timestamp=none", "--requirements",
            "=designated => " + requirement(metadata), str(path),
        ], "签名屏界")
    designated = verify(path, metadata)
    print("稳定签名验证通过：" + str(path))
    print(designated)
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (SigningError, OSError, ValueError) as error:
        print("签名未完成：" + redact(str(error)), file=sys.stderr)
        sys.exit(1)
