# 拾片产品介绍源工程

拾片 0.5.14 的真实原生截图 + 32 秒中文讲解动画，1920×1080 / 30 fps；无旁白，原创合成音乐。此工程在 macOS 上验证，依赖本机中文系统字体；其他平台的字体和渲染结果未验证。

```sh
npm ci
python3 build-film.py
ffmpeg -y -i assets/score.wav -af volume=12dB -codec:a libmp3lame -b:a 160k assets/score.mp3
npm run check
npm run dev
npm run render -- --output renders/shipian-intro.mp4 --fps 30
```

`build-film.py` 可重新生成场景和音乐；主时间线 `index.html` 已保留经校验的组装结果，供直接编辑和渲染。若修改时长，需同时调整主时间线的场景窗口、转场和音轨时长。

GSAP 3.14.2 来自官方 npm 包；`assets/gsap.min.js` 保留版权注释，遵循 [GSAP Standard License](https://gsap.com/standard-license/)，不受根目录 MIT 授权替代。制作框架 HyperFrames 的许可以安装的 npm 包为准。截图来自当前原生界面渲染，生成方法见 `../../source/README.md`，未修改界面中的控件。

渲染器固定为 HyperFrames 0.8.194。

原标题与分镜见 BRIEF.md / STORYBOARD.md；音轨是程序原创。演示图中的图片为本项目独立生成的示例素材。
