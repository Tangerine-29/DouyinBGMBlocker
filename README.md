# DouyinBGMBlocker

抖音越狱插件，用来屏蔽难听的背景音乐。

## 能干什么

- 长按视频菜单里一键屏蔽当前 BGM（按 `musicID` 记，同一首歌在不同视频里都生效）
- 关键词规则：歌名里同时出现指定词就静音
- 管理页里查看已屏蔽列表、批量取消、改关键词

## 环境

- 已越狱 iPhone，arm64
- rootless（Dopamine 等）
- 需要 [Theos](https://theos.dev)

## 编译安装

```bash
cd DouyinBGMBlocker
make package install
```

设备 IP 在 `Makefile` 里配，或者装完手动拷 deb。

## 怎么用

1. 打开抖音，长按视频
2. 点「屏蔽背景音乐」——当前这首会被静音
3. 同一行右侧齿轮进管理页

### 关键词写法

用英文逗号分隔，**所有词都要在歌名里出现**才算命中：

| 规则 | 会屏蔽 | 不会屏蔽 |
|------|--------|----------|
| `angel,中文` | angel（抖音中文女声版） | 只有 angel 的歌 |
| `魔性` | 歌名带「魔性」的 | — |

说明点标题旁的 ⓘ 看。

## 说明

- 只作用于抖音 `com.ss.iphone.ugc.Aweme`
- 屏蔽是静音，不是删音频轨道
- 和别的同类插件别一起装，容易冲突

## License

MIT
