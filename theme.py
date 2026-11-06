"""主题：界面配色，语义 token 化。

这套配色是**这个项目自己的**，不是照搬「墨读」的粉红：
    「墨读」是阅读器，长时间盯着暖粉调舒服；
    这里是管理仪表盘，一屏几十个数字和风险标记，
    中性偏冷的蓝灰骨架更耐看，风险色（绿/黄/橙/红）也不会糊在粉底上。

沿用「墨读」的是**结构**而不是颜色：token 化、留白、卡片分组、
文字按钮默认隐形、自绘图表。改配色只动这个文件，样式表一个字不用改。

配色原则：
  · 强调色是低饱和的石青蓝，只用在按钮、选中态、图表上，不铺大面积
  · 文字分五档明度（正文 / 标题 / 次要 / 说明 / 提示），靠层级而不是靠加粗
  · 风险四色全部降饱和，避免一屏红黄绿像交通灯
  · 深色不是简单反色：强调色提亮、风险色降饱和，否则暗底上会「发光」
"""
from string import Template

__all__ = ["THEMES", "theme_names", "palette", "current_theme", "set_theme",
           "render_stylesheet", "series_colors", "level_colors"]

LIGHT = {
    # 底色：暖纸 + 柔和青绿，像一本摊开的工作冒险手账
    "bg_win": "#f4f5ee",
    "bg_panel": "#fffdf7",
    "bg_read": "#f6f7ef",
    "bg_read_line": "#e8e6d9",
    "bg_chart": "#fffdf7",

    # 文字：五档明度
    "fg": "#36434a",
    "fg_strong": "#20323c",
    "fg_soft": "#566a71",
    "fg_dim": "#78898e",
    "fg_faint": "#a3b1b3",
    "fg_read": "#394b52",

    # 线条
    "line": "#e4e7de",
    "line_soft": "#eef0e8",
    "line_hair": "#f4f5ef",
    "line_input": "#d5ddd7",

    # 交互：深翡翠主色 + 黄铜高光
    "accent": "#4b9b8d",
    "accent_dim": "#347b70",
    "accent_deep": "#28645a",
    "accent_wash": "#e4f2ec",
    "accent_edge": "#bee0d5",
    "hover": "#eef6f2",
    "pressed": "#e5eee9",

    # 控件底色
    "btn_bg": "#fffdf7",
    "btn_bg_off": "#f3f5ef",
    "field_bg": "#fffdf7",
    "field_line": "#dce2dc",
    "field_focus": "#79b8aa",
    "disabled_fg": "#b6c1be",
    "muted_fg": "#78898e",

    # 其它
    "selection": "#cfe9e2",
    "menu_hover": "#eef6f2",
    "track": "#e8ece7",
    "scroll": "#c9d5d1",
    "scroll_hover": "#aebfba",
    "tooltip_bg": "#20323c",
    "tooltip_fg": "#fffdf7",
    "warn": "#b06a5a",

    # 工作冒险主题
    "ink": "#2d4555",
    "ink_soft": "#416d76",
    "ink_line": "#6a948e",
    "gold": "#e3a56c",
    "gold_soft": "#f9e6d2",
    "gold_edge": "#efcda8",
    "on_ink": "#fffdf7",
    "on_ink_dim": "#dcebe5",
    "hero_start": "#355f6d",
    "hero_end": "#5c8f86",
    "top_start": "#edf6f1",
    "top_end": "#fbebdb",
    "top_text": "#20323c",
    "top_dim": "#647a80",
}

DARK = {
    "bg_win": "#101817",
    "bg_panel": "#182521",
    "bg_read": "#141f1c",
    "bg_read_line": "#27352f",
    "bg_chart": "#182521",

    "fg": "#d9e4df",
    "fg_strong": "#f3f7f4",
    "fg_soft": "#b3c4bc",
    "fg_dim": "#82968d",
    "fg_faint": "#61726b",
    "fg_read": "#c9d8d1",

    "line": "#2a3933",
    "line_soft": "#23312c",
    "line_hair": "#1f2c28",
    "line_input": "#3a4b44",

    # 暗底上强调色提亮，黄铜高光保留暖意
    "accent": "#6fb8a2",
    "accent_dim": "#8fd1bd",
    "accent_deep": "#a9e0ce",
    "accent_wash": "#213730",
    "accent_edge": "#396356",
    "hover": "#202c28",
    "pressed": "#293731",

    "btn_bg": "#1d2c27",
    "btn_bg_off": "#17231f",
    "field_bg": "#15211d",
    "field_line": "#30413a",
    "field_focus": "#5e9f8b",
    "disabled_fg": "#596963",
    "muted_fg": "#82968d",

    "selection": "#2b443b",
    "menu_hover": "#202c28",
    "track": "#24332e",
    "scroll": "#35453e",
    "scroll_hover": "#495c54",
    "tooltip_bg": "#eaf2ee",
    "tooltip_fg": "#101817",
    "warn": "#d58d7b",

    # 工作冒险主题
    "ink": "#1f303d",
    "ink_soft": "#2c4c57",
    "ink_line": "#56787a",
    "gold": "#e5ad78",
    "gold_soft": "#4a392c",
    "gold_edge": "#88694e",
    "on_ink": "#f3faf6",
    "on_ink_dim": "#a8c0b6",
    "hero_start": "#243d4a",
    "hero_end": "#416c6b",
    "top_start": "#182521",
    "top_end": "#2d2924",
    "top_text": "#f3f7f4",
    "top_dim": "#a8bcb6",
}

THEMES = {"light": LIGHT, "dark": DARK}

#: 图表曲线配色。和界面蓝灰岔开——要同时区分多条线，
#: 用一组明度接近但色相分散的莫兰迪色，谁也压不过谁。
SERIES = {
    "light": ["#5f7893", "#a8737d", "#7f9e86", "#c4a76a", "#8a7fa8", "#6a9aa8"],
    "dark": ["#8ea8c4", "#c08893", "#8fb096", "#d4bb80", "#a894c4", "#7fb0c4"],
}

#: 风险等级配色。绿→黄→橙→红，但全部降饱和，
#: 免得一屏红黄绿像交通灯。深色下同样降饱和提亮。
LEVELS = {
    "light": {
        "健康": "#6f9a78",
        "关注": "#c0a860",
        "风险": "#c08457",
        "严重": "#a8606a",
    },
    "dark": {
        "健康": "#82ab8b",
        "关注": "#d0bb78",
        "风险": "#d29a72",
        "严重": "#bd7681",
    },
}

_current = "light"


def theme_names():
    return list(THEMES)


def set_theme(name):
    global _current
    if _current != name and name in THEMES:
        _current = name
    return _current


def current_theme():
    return _current


def palette():
    return dict(THEMES[_current])


def series_colors():
    return list(SERIES[_current])


def level_colors():
    return dict(LEVELS[_current])


def render_stylesheet(template_text, name=None):
    colors = THEMES.get(name or _current, LIGHT)
    return Template(template_text).safe_substitute(colors)
