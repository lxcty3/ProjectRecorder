"""打包成 Windows 可执行文件（PyInstaller）。

用法：
    py -m pip install pyinstaller
    py build.py              # 打包成文件夹（onedir），启动快
    py build.py --onefile    # 打包成单个 exe，方便发给别人，但启动慢几秒
    py build.py --clean      # 先删掉上次的 build/ dist/ 再打

产物：
    dist/项目记录器/项目记录器.exe   （onedir）
    dist/项目记录器.exe              （onefile）

关于随程序发布的文件：
    源码运行时，schema.sql 和 style.qss 从脚本旁边读；
    打包后它们被解压到 sys._MEIPASS。
    db.py 和 main.py 里的 _resource_path() / resource_path() 会判断这两种情况，
    所以资源一定要在本脚本的 BUNDLED 里列全——**漏了 schema.sql 会启动即崩**。
"""
import os
import shutil
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
NAME = "项目记录器"
ENTRY = "main.py"

#: 需要一起打进去的资源：源码相对路径 -> 打包后相对路径
#: schema.sql 是必须的，缺了数据库建不出来，程序一启动就报错
BUNDLED = [
    ("schema.sql", "."),
    ("style.qss", "."),
    ("README.md", "."),
    ("preview.html", "."),
    ("mobile/sql/community.sql", "."),
    ("mobile/sql/community-forum-v1.sql", "."),
    ("mobile/sql/organization-founders-v1.sql", "."),
    ("mobile/sql/platform-stability-v1.sql", "."),
    ("mobile/sql/community-identity-v1.sql", "."),
    ("mobile/sql/unified-platform.sql", "."),
    ("mobile/sql/work-intake-v1.sql", "."),
    ("mobile/sql/shareholder-meetings-v1.sql", "."),
    ("assets/app_icon.ico", "assets"),
    ("assets/app_icon.png", "assets"),
]

#: 这些模块程序里用不到，排掉能省不少体积
EXCLUDES = [
    "tkinter", "unittest", "pydoc_data", "test",
    "matplotlib", "numpy", "scipy", "pandas",
    "PyQt6.QtNetwork", "PyQt6.QtQml", "PyQt6.QtQuick",
    "PyQt6.QtQuick3D", "PyQt6.QtWebEngineCore", "PyQt6.QtWebEngineWidgets",
    "PyQt6.QtMultimedia", "PyQt6.QtBluetooth",
    "PyQt6.QtPositioning", "PyQt6.QtSerialPort", "PyQt6.QtDesigner",
    "PyQt6.QtTest", "PyQt6.QtHelp",
]

#: 同目录的模块。PyInstaller 一般能自动发现，
#: 但显式写出来更保险（尤其 check.py 那种只被间接引用的）
HIDDEN = [
    "db", "rules", "theme", "widgets", "chart", "detail", "export", "metrics",
    "server", "server_pages", "submit", "timer", "timer_ui",
    "knowledge_planet", "community_client", "community_ui",
    "cloud_integration", "collaboration", "intake_rules", "intake_ui",
    "meeting_rules", "meeting_ui", "organization_ui", "qrcode", "PIL",
]


def check_pyinstaller():
    try:
        import PyInstaller  # noqa: F401
    except ImportError:
        print("还没有 PyInstaller。先装：")
        print("    py -m pip install pyinstaller")
        return False
    return True


def check_sources():
    """打包前先确认关键文件在，少一个打出来的包就是坏的"""
    ok = True
    if not (HERE / ENTRY).is_file():
        print(f"找不到入口文件：{ENTRY}")
        ok = False
    # schema.sql 缺了会启动即崩，单独强调
    if not (HERE / "schema.sql").is_file():
        print("找不到 schema.sql —— 数据库建不出来，打包后程序无法启动。")
        ok = False
    if not (HERE / "style.qss").is_file():
        print("找不到 style.qss —— 界面会退回系统默认外观（不影响运行）。")
    return ok


def main():
    if not check_pyinstaller():
        return 1
    if not check_sources():
        return 1

    onefile = "--onefile" in sys.argv
    clean = "--clean" in sys.argv

    if clean:
        for folder in ("build", "dist"):
            target = HERE / folder
            if target.exists():
                shutil.rmtree(target)
                print(f"已删除 {folder}/")

    # Windows 上用分号分隔 --add-data；os.pathsep 在这个平台就是分号
    data_specs = []
    for source, target in BUNDLED:
        path = HERE / source
        if path.exists():
            data_specs += ["--add-data", f"{path}{os.pathsep}{target}"]
        else:
            print(f"  （跳过不存在的资源：{source}）")

    command = [
        sys.executable, "-m", "PyInstaller",
        "--noconfirm",
        "--windowed",                 # 不弹黑色控制台窗口
        "--name", NAME,
        "--paths", str(HERE),         # 让 PyInstaller 找到同目录的模块
    ]
    command += ["--onefile"] if onefile else ["--onedir"]
    for module in EXCLUDES:
        command += ["--exclude-module", module]
    for module in HIDDEN:
        command += ["--hidden-import", module]
    icon_path = HERE / "assets" / "app_icon.ico"
    if icon_path.is_file():
        command += ["--icon", str(icon_path)]
    command += data_specs
    command.append(str(HERE / ENTRY))

    print("\n执行：")
    print("  " + " ".join(f'"{c}"' if " " in c else c for c in command))
    print()
    result = subprocess.run(command, cwd=str(HERE))
    if result.returncode != 0:
        print("\n打包失败，把上面的输出贴出来看看。")
        return result.returncode

    print("\n打包完成：")
    if onefile:
        print(f"  {HERE / 'dist' / (NAME + '.exe')}")
    else:
        print(f"  {HERE / 'dist' / NAME / (NAME + '.exe')}")

    print("\n提醒：")
    print("  · 数据存在 ~/ProjectRecorder/projects.db，不在 exe 旁边。")
    print("    换台机器（用户名不同）就是全新的空库，不会带着别人的数据。")
    print("  · 发给别人前，自己先双击跑一遍，")
    print("    重点确认窗口能开、新建项目能存、小助手能回答。")
    return 0


if __name__ == "__main__":
    sys.exit(main())
