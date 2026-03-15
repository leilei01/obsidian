# OpenClaw 音频功能（ASR+TTS）完整配置教程（适配阿里云海外 Ubuntu 服务器）

## 文档说明

本教程基于 **4核8G 阿里云海外 Ubuntu 服务器** 环境，针对配置过程中遇到的系统权限、镜像源、官方配置规范等问题，提供可直接落地的解决方案，全程符合 OpenClaw 官方标准，支持中文语音识别（ASR）和语音合成（TTS）。

---

## 一、环境基础信息

- 服务器配置：4核8G Ubuntu（23.04+）
- OpenClaw 状态：已预装并运行，需新增音频功能
- 核心目标：实现「语音输入→文字识别→语音输出」全链路交互

---

## 二、前置条件（硬件/系统）

1. **硬件**：4核8G 完全满足（官方推荐生产环境配置），支持 3-5 路并发语音交互；
2. **系统依赖**：需提前安装 `ffmpeg`（音频格式转换）、Python3、Node.js（OpenClaw 基础）；
3. **网络**：阿里云海外服务器需访问海外 PyPI 源（避免 edge-tts 安装失败）。

---

## 三、完整配置步骤（含问题解决）

### 步骤 1：安装音频基础依赖 ffmpeg

#### 操作命令

```bash
sudo apt update && sudo apt install -y ffmpeg
# 验证安装
ffmpeg -version
```

#### 验证标准

输出 `ffmpeg version x.x.x` 即成功，无报错。

---

### 步骤 2：安装本地语音识别引擎（faster-whisper）

#### 问题说明

Ubuntu 23.04+ 启用 PEP 668 保护，禁止直接用 `pip3` 安装系统级包，需用虚拟环境。

#### 操作命令

```bash
# 1. 创建专用虚拟环境（路径：/data/faster-whisper）
sudo mkdir -p /data && sudo chown -R $USER:$USER /data
python3 -m venv /data/faster-whisper

# 2. 激活虚拟环境
source /data/faster-whisper/bin/activate

# 3. 安装 faster-whisper（轻量版 Whisper，适配服务器）
pip install faster-whisper

# 4. 验证安装
python -c "import faster_whisper; print(faster_whisper.__version__)"

# 5. 测试识别功能（下载测试音频）
wget https://cdn.openclaw.ai/test-audio-zh.wav -O /data/test-zh.wav
python - <<EOF
from faster_whisper import WhisperModel
model = WhisperModel("tiny", device="cpu", compute_type="int8")
segments, info = model.transcribe("/data/test-zh.wav", language="zh")
print("识别结果：")
for segment in segments:
    print(segment.text)
EOF
```

#### 验证标准

- 虚拟环境激活后终端显示 `(faster-whisper)`；
- 能输出 faster-whisper 版本号（如 1.2.1）；
- 测试识别输出清晰中文文本（如"今天天气很好，适合出门散步"）。

---

### 步骤 3：编写语音识别脚本（符合 OpenClaw 官方规范）

#### 问题说明

OpenClaw 官方配置中 `tools.media.audio.models.0.type` 仅支持 `provider`/`cli`，不支持直接写 `python`，需封装为 CLI 脚本调用。

#### 操作命令

```bash
# 1. 创建识别脚本
nano /data/whisper-recognize.py
```

#### 脚本内容（复制粘贴）

```python
#!/usr/bin/env python3
import sys
from faster_whisper import WhisperModel

def main(audio_path):
    # 加载轻量模型（适配4核8G）
    model = WhisperModel("tiny", device="cpu", compute_type="int8")
    # 识别中文音频
    segments, info = model.transcribe(audio_path, language="zh")
    # 输出识别结果（OpenClaw 读取该输出）
    for segment in segments:
        print(segment.text.strip())

if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("请传入音频文件路径", file=sys.stderr)
        sys.exit(1)
    main(sys.argv[1])
```

#### 赋予执行权限并测试

```bash
chmod +x /data/whisper-recognize.py
# 测试脚本
/data/faster-whisper/bin/python /data/whisper-recognize.py /data/test-zh.wav
```

---

### 步骤 4：配置 OpenClaw 音频参数（官方标准）

#### 操作命令

```bash
# 1. 备份原有配置
cd ~/.openclaw && cp openclaw.json openclaw.json.bak

# 2. 编辑配置文件
nano ~/.openclaw/openclaw.json
```

#### 核心配置内容（替换/新增）

```json
{
  "meta": {
    "name": "MyOpenClaw",
    "version": "1.0.0"
  },
  "server": {
    "host": "0.0.0.0",
    "port": 18789
  },
  "tools": {
    "media": {
      "audio": {
        "enabled": true,
        "maxBytes": 20971520,
        "models": [
          {
            "type": "cli",
            "command": "/data/faster-whisper/bin/python",
            "args": [
              "/data/whisper-recognize.py",
              "{{MediaPath}}"
            ],
            "timeoutSeconds": 60
          }
        ]
      }
    }
  },
  "messages": {
    "tts": {
      "auto": "inbound",
      "provider": "edge",
      "edge": {
        "enabled": true,
        "voice": "zh-cn-xiaoxiaoneural",
        "lang": "zh-cn",
        "outputFormat": "audio-24khz-48kbitrate-mono-mp3"
      }
    }
  }
}
```

#### 保存配置

按 `Ctrl+O` → 回车 → `Ctrl+X` 退出编辑器。

---

### 步骤 5：安装语音合成引擎（edge-tts）

#### 问题说明

阿里云镜像源超时，需换用海外 PyPI 官方源；OpenClaw 仅支持 `elevenlabs`/`openai`/`edge` 三种 TTS 提供商，优先选免费的 `edge`。

#### 操作命令

```bash
# 1. 退出虚拟环境
deactivate

# 2. 用海外源安装 edge-tts
pip3 install edge-tts -i https://pypi.org/simple --break-system-packages

# 3. 验证安装
edge-tts --version

# 4. 测试TTS功能
edge-tts --voice zh-cn-xiaoxiaoneural --text "OpenClaw语音测试" --write-media /data/test-tts.mp3
ls -lh /data/test-tts.mp3
```

---

### 步骤 6：重启 OpenClaw 服务生效

```bash
# 停止现有服务
openclaw gateway stop

# 启动服务（带详细日志）
openclaw gateway start --verbose
```

#### 启动成功标志

终端输出无报错，包含以下关键信息：

```
[openclaw] Loaded config from /home/leilei/.openclaw/openclaw.json
[openclaw] Media tools: Audio recognition enabled (cli mode)
[openclaw] TTS enabled (provider: edge, voice: zh-cn-xiaoxiaoneural)
[openclaw] Gateway started on http://0.0.0.0:18789
```

---

## 四、全链路测试

### 1. 浏览器端测试（推荐）

1. 访问 `http://服务器IP:18789`；
2. 点击输入框右侧麦克风图标，允许浏览器访问麦克风；
3. 说一句中文（如"测试语音识别和合成"）；
4. 验证结果：输入框显示文字，系统自动播放语音回复。

### 2. 命令行兜底测试

```bash
# 验证ASR
/data/faster-whisper/bin/python /data/whisper-recognize.py /data/test-zh.wav

# 验证TTS
edge-tts --voice zh-cn-xiaoxiaoneural --text "测试成功" --write-media /data/tts-success.mp3
```

---

## 五、常见问题排查

| 问题现象 | 原因 | 解决方案 |
|---------|------|---------|
| pip3 安装报错 `externally-managed-environment` | Ubuntu 系统保护系统Python环境 | 使用虚拟环境安装（步骤2） |
| OpenClaw 配置报错 `Invalid input` | type 字段写了非官方值（如python） | 改为 `cli` 类型，封装识别脚本（步骤3） |
| edge-tts 安装超时/找不到版本 | 国内镜像源访问失败 | 换用海外源 `https://pypi.org/simple`（步骤5） |
| OpenClaw 启动报错 `Invalid option` | TTS provider 写了非官方值 | 恢复为 `edge`（步骤4配置） |
| 语音识别无结果 | 脚本路径/权限错误 | 检查 `/data/whisper-recognize.py` 权限（`chmod +x`） |

---

## 六、关键优化建议（4核8G服务器）

1. **模型选择**：优先用 `tiny`/`base` 模型（轻量，内存占用<1GB），避免 `medium/large`；
2. **并发限制**：在 `openclaw.json` 中添加 `server.maxConcurrentTasks: 3`，避免资源耗尽；
3. **后台运行**：用 `nohup openclaw gateway start &` 让服务后台运行，避免终端关闭中断；
4. **端口放行**：服务器安全组放行 18789 端口（TCP），确保浏览器能访问。

---

## 七、总结

1. 4核8G 阿里云海外服务器完全适配 OpenClaw 音频功能，无需升级硬件；
2. 核心配置需严格遵循 OpenClaw 官方规范（如 `type: cli`、`provider: edge`），避免非标准参数；
3. 海外服务器需适配网络环境（换海外源安装 edge-tts），系统权限问题通过虚拟环境解决；
4. 配置完成后，可实现「语音输入→文字识别→语音输出」全链路交互，满足单用户/小团队使用需求。

---

*文档创建时间：2026-03-15*
*适用环境：阿里云海外 Ubuntu 服务器 + OpenClaw*
