# Secure Boot 与 MOK

本次实验保持 Secure Boot 为 Enabled。流程使用本地 Machine Owner Key
给现场构建的 `xdma.ko` 签名，再通过 MOK Manager 注册公钥。私钥不能
提交到 Git。

以下命令是手工操作示例；先确认系统、路径和 BitLocker 恢复方式，再执行。

## 1. 创建本地密钥

```bash
mkdir -p "$HOME/.local/share/memblaze-xdma-mok"
chmod 700 "$HOME/.local/share/memblaze-xdma-mok"
cd "$HOME/.local/share/memblaze-xdma-mok"

openssl req -new -x509 -newkey rsa:2048 \
  -keyout MOK.priv -outform DER -out MOK.der \
  -nodes -days 3650 -subj "/CN=Local XDMA module signing/"
chmod 600 MOK.priv
```

`MOK.priv` 是私钥；只应由本机管理员持有。`MOK.der` 是可注册和检查的
公钥证书。

## 2. 注册公钥

```bash
sudo mokutil --import "$HOME/.local/share/memblaze-xdma-mok/MOK.der"
```

命令会要求设置一次性密码。重启进入 MOK Manager 后选择 Enroll MOK，
确认指纹并输入该密码。它修改的是固件信任数据库，操作前应备份 Windows
BitLocker 恢复密钥；不需要关闭 Secure Boot，也不要重置 UEFI keys。

## 3. 给当前内核的模块签名

先运行 `linux/02_build_driver.sh`。然后载入它生成的
`build_paths.env`，或按日志中的 `Module=` 路径定位 `xdma.ko`：

```bash
KREL="$(uname -r)"
SIGN_FILE="/usr/src/linux-headers-$KREL/scripts/sign-file"
MODULE="$HOME/memblaze-xdma-work/b8466090-aba9086b051e/$KREL/dma_ip_drivers-b8466090/XDMA/linux-kernel/xdma/xdma.ko"

sudo "$SIGN_FILE" sha256 \
  "$HOME/.local/share/memblaze-xdma-mok/MOK.priv" \
  "$HOME/.local/share/memblaze-xdma-mok/MOK.der" \
  "$MODULE"
```

模块与运行内核必须匹配。内核更新后，重新构建并签名新模块。

## 4. 只读检查

```bash
./linux/03_secure_boot_status.sh \
  "$HOME/.local/share/memblaze-xdma-mok/MOK.der"
```

不同 `mokutil` 版本的 `--test-key` 返回码不一致，还可能在结论前输出
keyring warning。脚本按完整文本行判断注册状态，并核对模块签名 key 与
证书 serial；不把 Subject Key Identifier 当成 serial。

`SECURE_BOOT_STATUS=READY` 是加载前检查。最终证据仍是
`linux/04_load_verify.sh` 的 `insmod` 成功、内核没有 key rejection，
且目标 endpoint 实际绑定到 `xdma`。

## 恢复

测试结束运行 `linux/99_cleanup.sh` 卸载模块。删除本地文件不会自动从
MOK 数据库撤销已注册证书；如果确实要撤销，应使用 `mokutil --delete`
并在下一次 MOK Manager 中确认。撤销属于独立的固件信任变更，不是正常
XDMA 清理步骤。
