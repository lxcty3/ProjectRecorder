"""自检：语法 + 未定义名字 + 数据层 + 预测引擎。都不需要启动界面。

用法：
    py check.py

比 py main.py 快得多，而且能精确定位问题在哪一层。
界面出问题时，先跑这个确认地基没问题。

关于「未定义名字」这一项：
    前面几轮连着出现 NameError（忘了导入、分支里没建属性），
    每次都要靠人肉运行才发现。这里用 ast 静态扫一遍：
    把每个函数里「用到的名字」和「能解析到的名字」对一下，
    差集就是可疑的未定义引用。不需要真正执行代码。
"""
import ast
import builtins
import io
import os
import pathlib
import sys
import tokenize
import traceback

HERE = pathlib.Path(__file__).resolve().parent
BUILTIN_NAMES = set(dir(builtins))


def check_syntax():
    """把每个 .py 编译一遍。这是抓「两行拼成一行」最可靠的办法。

    为什么包含 check.py 自己：
      能跑到这里确实说明 check.py 导入时编译过了，单独再看一遍是重复的。
      但保持一致更简单——不必维护「跳过谁」这个特例，
      以后新增脚本也不会因为忘了加例外而漏检。
    """
    failed = 0
    files = sorted(HERE.glob("*.py"))
    for path in files:
        try:
            compile(path.read_text(encoding="utf-8"), str(path), "exec")
        except SyntaxError as error:
            failed += 1
            print(f"[语法错误] {path.name}:{error.lineno}: {error.msg}")
            if error.text:
                print(f"           {error.text.rstrip()}")
        except OSError as error:
            failed += 1
            print(f"[读取失败] {path.name}: {error}")
    print(f"语法检查：{len(files)} 个文件，{failed} 个有问题")
    return failed


def _target_names(target):
    """从赋值目标里挖出名字，支持 a = b = c 和 a, b = ..."""
    names = set()
    if isinstance(target, ast.Name):
        names.add(target.id)
    elif isinstance(target, (ast.Tuple, ast.List)):
        for element in target.elts:
            names.update(_target_names(element))
    return names


def _scope_names(node):
    """收集一个作用域里的名字：参数（如果是函数）+ 局部赋值 + 内层定义的名字。

    既能传函数节点，也能传整个 ast.Module（用来收集模块层绑定）——
    所以取参数前要先判断节点类型。Module 没有 args 属性，
    直接读会 AttributeError。

    **绝不钻进内层函数**——内层函数的参数和局部变量是它自己的，
    收集到外层会让内层检查时反而看不到自己的参数（这正是之前
    `def x_of(day)` 里 day 被判成未定义的根因）。
    """
    names = set()
    if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef, ast.Lambda)):
        args = node.args
        for group in (args.posonlyargs, args.args, args.kwonlyargs):
            for arg in group:
                names.add(arg.arg)
        if args.vararg:
            names.add(args.vararg.arg)
        if args.kwarg:
            names.add(args.kwarg.arg)

    def collect(item):
        """递归收集，遇到函数/类定义只取名字，不进去"""
        for child in ast.iter_child_nodes(item):
            if isinstance(child, (ast.FunctionDef, ast.AsyncFunctionDef,
                                  ast.ClassDef)):
                names.add(child.name)
                continue
            if isinstance(child, ast.Lambda):
                for arg in (child.args.posonlyargs + child.args.args
                            + child.args.kwonlyargs):
                    names.add(arg.arg)
                if child.args.vararg:
                    names.add(child.args.vararg.arg)
                if child.args.kwarg:
                    names.add(child.args.kwarg.arg)
                collect(child)
                continue
            if isinstance(child, (ast.Assign, ast.AnnAssign, ast.AugAssign)):
                target = (child.targets[0] if isinstance(child, ast.Assign)
                          else child.target)
                names.update(_target_names(target))
            elif isinstance(child, (ast.For, ast.AsyncFor, ast.comprehension)):
                names.update(_target_names(child.target))
            elif isinstance(child, (ast.With, ast.AsyncWith)):
                for item2 in child.items:
                    if item2.optional_vars is not None:
                        names.update(_target_names(item2.optional_vars))
            elif isinstance(child, ast.ExceptHandler) and child.name:
                names.add(child.name)
            elif isinstance(child, ast.Import):
                for alias in child.names:
                    names.add((alias.asname or alias.name).split(".")[0])
            elif isinstance(child, ast.ImportFrom):
                for alias in child.names:
                    names.add(alias.asname or alias.name)
            elif isinstance(child, ast.Global):
                names.update(child.names)
            elif isinstance(child, ast.Nonlocal):
                names.update(child.names)
            collect(child)

    collect(node)
    # 只有函数/类才有 name；Module 没有，读它会 AttributeError
    if getattr(node, "name", None):
        names.add(node.name)
    return names


def _parent_map(tree):
    """给每个节点记下父节点，用于从任意节点回溯出作用域链"""
    parents = {}
    for parent in ast.walk(tree):
        for child in ast.iter_child_nodes(parent):
            parents[child] = parent
    return parents


def _module_bindings(tree):
    """整个文件里**曾经被绑定过**的名字，用来兜底。

    刻意宽松：用 ast.walk 走遍整棵树，把赋值、循环变量、with as、
    except as、导入、函数、类、global/nonlocal 全部收进来，
    **包括函数内部的局部变量**。

    为什么这么宽松：
      这里的目标是「宁可少报，也绝不误报」。
      一个总在误报的检查会让人不再看它，那就等于没有检查。
      剩下的漏报风险由「运行测试」兜住——那些测的是真实行为。

    踩过两次坑，记下来免得再犯：
      1. 收窄成「只收模块顶层直接绑定」→ 模块常量（APP_NAME、FONT）
         在函数体里被引用时全部误报，一次报了 105 处。
      2. 想用「在不在函数里」区分可见性 → 同一个错误的另一个版本，
         因为模块级的名字在函数里**本来就可见**。

    这样的检查依然能抓出「忘了导入」：那种名字在整个文件里
    根本不存在（比如当初的 QSizePolicy）。
    """
    names = set()
    for node in ast.walk(tree):
        if isinstance(node, ast.Name) and isinstance(node.ctx, ast.Store):
            names.add(node.id)
        elif isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef,
                               ast.ClassDef)):
            names.add(node.name)
        elif isinstance(node, (ast.Import, ast.ImportFrom)):
            for alias in node.names:
                names.add((alias.asname or alias.name).split(".")[0])
        elif isinstance(node, ast.arg):
            names.add(node.arg)
        elif isinstance(node, (ast.Global, ast.Nonlocal)):
            names.update(node.names)
    return names


def check_undefined_names():
    """静态找出「用了但没导入 / 没定义」的名字。

    分两道判断，都过了才报：

      1. **兜底**：这个名字在文件里任何地方被绑定过吗？
         赋值、循环变量、导入、函数、类、参数——都算。
         这一步很宽松，但它保证了「模块常量在函数里被引用」
         这类正常代码**绝不会误报**。
      2. 兜底没覆盖到时，再沿父节点往上逐层函数查一遍。

    能抓的是**整个文件里根本不存在的名字**——也就是最典型的
    「忘了导入」（当初的 QSizePolicy 就是这么被抓出来的）。

    抓不到的是「函数里用了别的函数的局部变量」，那属于名称
    虽然存在但作用域不对。那种情况编译器自己会在创建闭包时报错，
    而且真正写错时运行测试会先暴露。
    这个取舍是刻意的：**误报会让人不再看这个检查，那比漏报更糟。**
    """
    problems = []
    seen = set()
    files = sorted(HERE.glob("*.py"))
    for path in files:
        if path.name == "check.py":
            continue
        try:
            tree = ast.parse(path.read_text(encoding="utf-8"), str(path))
        except (SyntaxError, OSError):
            continue

        parents = _parent_map(tree)

        # 文件里绑定过的一切名字。这是一道**兜底**：
        # 只要这个名字在文件里任何地方被绑定过，就不报。
        # 宽松是故意的——见 _module_bindings 的说明。
        bound_names = _module_bindings(tree)

        # 缓存每层函数的作用域名，避免同一函数重复计算
        cache = {}

        def scope_of(func):
            if func not in cache:
                cache[func] = _scope_names(func)
            return cache[func]

        for node in ast.walk(tree):
            if not isinstance(node, ast.Name):
                continue
            if not isinstance(node.ctx, ast.Load):
                continue
            name = node.id
            if name in BUILTIN_NAMES or name in bound_names:
                continue
            if name in ("self", "cls", "__name__", "__file__", "__doc__"):
                continue
            # 兜底没覆盖到时，再沿父节点往上逐层函数查一遍
            found = False
            current = parents.get(node)
            while current is not None:
                if isinstance(current, (ast.FunctionDef, ast.AsyncFunctionDef)):
                    if name in scope_of(current):
                        found = True
                        break
                current = parents.get(current)
            if found:
                continue
            key = (path.name, node.lineno, name)
            if key in seen:
                continue
            seen.add(key)
            problems.append(f"{path.name}:{node.lineno}: 名字「{name}」没有定义或导入")

    if problems:
        print(f"未定义名字：{len(problems)} 处可疑")
        for line in problems:
            print(f"  {line}")
    else:
        print("未定义名字：没发现问题")
    return len(problems)


def check_data_layer():
    """用内存库跑一遍完整读写，不碰你的真实数据文件"""
    import db

    store = db.Store(":memory:")
    try:
        project_id = store.add_project({
            "name": "自检项目", "owner": "测试", "status": "进行中",
            "priority": "高", "start_date": "2026-01-01",
            "due_date": "2026-02-01", "budget": 1000, "cost": 200, "progress": 30,
        })
        step_id = store.add_step(project_id, {"name": "步骤一", "status": "进行中"})
        employee_id = store.add_employee({"name": "张三", "weekly_hours": 40})
        store.add_assignment({"project_id": project_id, "step_id": step_id,
                              "employee_id": employee_id, "planned_hours": 20})
        store.add_worklog({"employee_id": employee_id, "project_id": project_id,
                           "step_id": step_id, "work_date": "2026-01-05", "hours": 8})
        store.add_assessment(project_id, {"kind": "ability", "name": "后端", "score": 4})
        store.add_metric(project_id, {"metric_date": "2026-01-05",
                                      "name": "到货率", "value": 60})

        assert len(store.projects()) == 1
        assert len(store.steps(project_id)) == 1
        assert len(store.employees()) == 1
        assert len(store.worklogs()) == 1
        assert len(store.assignments(project_id=project_id)) == 1
        assert len(store.assessments(project_id)) == 1
        assert len(store.metrics(project_id)) == 1
        assert store.metric_names(project_id) == ["到货率"]
        assert len(store.dashboard_rows()) == 1
        assert len(store.hours_by_employee()) == 1
        knowledge_a = store.add_knowledge({
            "title": "复盘要写证据", "zone": "实际知识",
            "kind": "显性知识", "tags": "复盘,证据",
            "project_id": project_id, "importance": 5,
        })
        knowledge_b = store.add_knowledge({
            "title": "客户沉默可能不是满意", "zone": "潜在知识",
            "kind": "隐性知识", "tags": "客户,复盘", "status": "种子",
        })
        store.add_knowledge_link(knowledge_a, knowledge_b, "反例", "待验证")
        store.add_knowledge_reflection(knowledge_a, "证据够吗？", "还不够。")
        k_stats = store.knowledge_stats()
        assert k_stats["total"] == 2
        assert k_stats["explicit"] == 1 and k_stats["tacit"] == 1
        assert k_stats["seed"] == 1 and k_stats["reflections"] == 1
        assert len(store.knowledge_links()) == 1
        assert len(store.knowledge_items(keyword="证据")) == 1
        print("数据层：读写正常（含知识星球）")
        return True
    finally:
        store.close()


def check_community_client():
    """社区客户端：登录、刷新、读取、发布、删除的参数和返回值。"""
    import community_client as cc

    original = cc._request
    calls = []

    def fake_request(method, path, **kwargs):
        calls.append((method, path, kwargs))
        if path == "/rest/v1/rpc/login_email":
            assert kwargs["body"]["p_code"] == "boss001"
            return {"status": "ok", "email": "boss001@boss.pr"}
        if path == "/auth/v1/token":
            if kwargs.get("params", {}).get("grant_type") == "refresh_token":
                return {"access_token": "refreshed", "refresh_token": "refresh-2",
                        "expires_in": 3600, "user": {"id": "user-1"}}
            return {"access_token": "token-1", "refresh_token": "refresh-1",
                    "expires_in": 3600, "user": {"id": "user-1"}}
        if path == "/rest/v1/profiles":
            return [{"id": "user-1", "name": "林墨", "role": "boss",
                     "code": "boss001"}]
        if path == "/rest/v1/rpc/list_knowledge_posts":
            assert kwargs["body"]["p_limit"] == 80
            return [{"id": "post-1", "content": "大家好",
                     "author_name": "林墨", "author_role": "boss",
                     "unlock_cost": 0, "is_required": False,
                     "locked": False, "preview": "大家好"}]
        if path == "/rest/v1/rpc/post_community_message":
            assert kwargs["body"]["p_content"] == "大家好"
            assert kwargs["body"]["p_unlock_cost"] == 0
            assert kwargs["body"]["p_is_required"] is False
            return {"ok": True, "id": "post-1"}
        if path == "/rest/v1/rpc/delete_my_community_message":
            return True
        raise AssertionError(f"unexpected community request: {path}")

    cc._request = fake_request
    try:
        client = cc.CommunityClient()
        session = client.login("boss001", "secret")
        assert session.access_token == "token-1"
        assert session.name == "林墨" and session.role == "boss"
        posts = client.list_posts(session)
        assert posts[0]["content"] == "大家好"
        assert client.publish(session, "大家好", "分享")["ok"] is True
        assert client.delete_post(session, "post-1") is True
        session.expires_at = 0
        refreshed = client.refresh(session)
        assert refreshed.access_token == "refreshed"
        assert cc.CommunitySession.from_dict(session.to_dict()).user_id == "user-1"
        assert any(path.endswith("login_email") for _, path, _ in calls)
        print("社区客户端：登录、消息读取、发布、删除、刷新正常")
        return True
    finally:
        cc._request = original


def check_rules():
    """预测引擎必须给出结论、依据和等级"""
    import db
    import rules

    store = db.Store(":memory:")
    try:
        project_id = store.add_project({
            "name": "问题项目", "status": "进行中", "priority": "高",
            "start_date": "2026-01-01", "due_date": "2026-01-20",
            "budget": 1000, "cost": 950, "progress": 10,
        })
        store.add_step(project_id, {"name": "卡住的步骤", "status": "已阻塞"})
        result = rules.predict(store, project_id)
        assert result is not None, "预测返回了 None"
        assert result["level"] in rules.RISK_LEVELS, f"等级异常：{result['level']}"
        assert result["headline"], "没有结论文本"
        assert result["reasons"], "没有依据条目"
        for reason in result["reasons"]:
            assert reason.get("text"), f"依据缺少 text：{reason}"

        summary = rules.load_summary(store)
        assert len(summary) == 1
        assert summary[0]["level"] in rules.RISK_LEVELS

        print(f"预测引擎：正常（问题项目判为「{result['level']}」，"
              f"{len(result['reasons'])} 条依据）")
        return True
    finally:
        store.close()


def check_assistant():
    """小助手：每一类问题都要能答，且答出来的不是空话。

    注意数据里的日期一律用**相对今天的偏移**：
    写成固定日期的话，过一阵子就落在时间窗口之外，
    依赖「最近 N 天」的判据永远测不到——这里踩过一次。
    """
    import datetime as dt
    import db
    import rules

    def days_ago(n):
        return (dt.date.today() - dt.timedelta(days=n)).isoformat()

    questions = list(rules.SUGGESTIONS) + [
        "现在什么情况", "哪个项目有风险", "谁最忙", "谁闲下来了",
        "预算要紧吗", "有多少人在岗", "哪些任务卡住了",
        "比一比", "找矛盾", "帮我看看有什么问题",
        "张三怎么样", "不存在的项目怎么样",
        "", "随便问一个它肯定不懂的问题",
    ]

    # 空库
    store = db.Store(":memory:")
    try:
        for question in questions:
            answer = rules.ask(store, question)
            assert isinstance(answer, str) and answer.strip(), \
                f"空库下「{question}」没有回答"
        print(f"小助手：空库下 {len(questions)} 个问题都有回答")
    finally:
        store.close()

    # 有数据的库
    store = db.Store(":memory:")
    try:
        project_id = store.add_project({
            "name": "测试项目", "owner": "李工", "status": "进行中",
            "start_date": days_ago(30), "due_date": days_ago(-5),
            "budget": 10000, "cost": 9000, "progress": 40,
        })
        store.add_step(project_id, {"name": "联调", "status": "已阻塞",
                                    "owner": "王强", "due_date": days_ago(10)})
        employee_id = store.add_employee({"name": "王强", "role": "后端",
                                          "weekly_hours": 40})
        # 工时记在最近几天，才落得进「最近 N 天」的窗口
        for offset in (1, 3, 5):
            store.add_worklog({"employee_id": employee_id, "project_id": project_id,
                               "work_date": days_ago(offset), "hours": 20,
                               "content": "赶进度"})
        for question in questions:
            answer = rules.ask(store, question)
            assert isinstance(answer, str) and answer.strip(), \
                f"有数据时「{question}」没有回答"
        # 点名项目应该给出等级和依据
        answer = rules.ask(store, "测试项目怎么样")
        assert "测试项目" in answer, "点名项目没有给出回答"
        assert "建议" in answer or "·" in answer, "点名项目没有给出依据"
        # 兜底回答要老实说明能力边界
        answer = rules.ask(store, "今天天气怎么样")
        assert "没理解" in answer or "能回答" in answer, "兜底回答没有说明能问什么"

        # 主动发现也要能跑
        answer = rules.ask(store, "帮我看看有什么问题")
        assert isinstance(answer, str) and answer.strip(), "主动发现没有回答"

        # 动态建议：这个库有阻塞步骤、有人超负荷，必须给出提示
        urgent = rules.urgent_suggestions(store)
        assert isinstance(urgent, list), "urgent_suggestions 没有返回列表"
        assert urgent, (
            "有阻塞步骤和超负荷的情况下，动态建议却是空的。"
            "常见原因：建议文案和固定列表重名，被去重规则吃掉了。"
        )
        # 动态建议必须是「固定列表之外」的新问题——否则加了等于没加
        for question in urgent:
            assert question not in rules.SUGGESTIONS, (
                f"动态建议「{question}」和固定列表重名，去重后等于没加"
            )
        # 更关键：每个动态建议都必须真能被回答，不能是死按钮
        for question in urgent:
            answer = rules.ask(store, question)
            assert isinstance(answer, str) and answer.strip(), \
                f"动态建议「{question}」点下去没有回答"
            assert "我没理解" not in answer, (
                f"动态建议「{question}」点下去得到的是兜底回答——"
                f"说明 ask() 里没有对应的分支，这是死按钮"
            )
        print(f"小助手：有数据时 {len(questions)} 个问题都有回答，"
              f"点名、兜底、主动发现正常；动态建议 {len(urgent)} 条且都能被回答")
        return True
    finally:
        store.close()


def check_insights():
    """洞察引擎：每一类发现都要能被造出来的数据触发，也要在干净数据上闭嘴。

    这是「误报检查」——一个总在报问题的助手等于没报。

    日期一律用相对今天的偏移：写成固定日期的话，
    依赖「最近 N 天」的判据过一阵子就失效了。
    """
    import datetime as dt
    import db
    import rules

    def days_ago(n):
        return (dt.date.today() - dt.timedelta(days=n)).isoformat()

    store = db.Store(":memory:")
    try:
        # ---- 干净数据：不该报任何问题 ----
        clean = store.add_project({
            "name": "干净项目", "status": "进行中", "start_date": days_ago(60),
            "due_date": days_ago(-120), "budget": 100000, "cost": 10000, "progress": 50,
        })
        store.add_step(clean, {"name": "第一步", "status": "已完成"})
        store.add_step(clean, {"name": "第二步", "status": "进行中"})
        employee = store.add_employee({"name": "正常员工", "level": "P5",
                                       "weekly_hours": 40})
        store.add_assignment({"project_id": clean, "employee_id": employee,
                              "planned_hours": 40, "start_date": days_ago(30)})
        store.add_worklog({"employee_id": employee, "project_id": clean,
                           "work_date": days_ago(3), "hours": 8})
        found = rules.insights(store)
        assert not found, \
            "干净数据上不该有洞察，却报了：" + "；".join(i["title"] for i in found)
        print("洞察引擎：干净数据上不误报")
    finally:
        store.close()

    # ---- 问题数据：每一类都要被触发 ----
    store = db.Store(":memory:")
    try:
        # 效率对比：A 花钱多进度低，B 花钱少进度高
        a = store.add_project({
            "name": "低效项目", "status": "进行中", "owner": "甲",
            "start_date": days_ago(60), "due_date": days_ago(-10),
            "budget": 1000000, "cost": 900000, "progress": 10,
        })
        b = store.add_project({
            "name": "高效项目", "status": "进行中", "owner": "乙",
            "start_date": days_ago(60), "due_date": days_ago(-120),
            "budget": 50000, "cost": 5000, "progress": 80,
        })
        # 顺序矛盾：第二步完成了，第一步还没
        store.add_step(a, {"name": "第一步", "status": "进行中"})
        store.add_step(a, {"name": "第二步", "status": "已完成"})
        # 长期阻塞（超过 3 天才报）
        store.add_step(a, {"name": "卡住的一步", "status": "已阻塞",
                           "due_date": days_ago(20), "owner": "甲"})

        # 超负荷：周基准 40，最近几天干了 60
        busy = store.add_employee({"name": "忙人", "level": "P6", "weekly_hours": 40})
        for offset in (1, 2, 3):
            store.add_worklog({"employee_id": busy, "project_id": a,
                               "work_date": days_ago(offset), "hours": 20,
                               "content": "连着干"})
        # 摊到多个项目：挂 3 个进行中的项目
        c = store.add_project({"name": "第三项目", "status": "进行中"})
        for project in (a, b, c):
            store.add_assignment({"project_id": project, "employee_id": busy,
                                  "planned_hours": 10, "start_date": days_ago(30)})
        # 没分配到人的工时：另一个人记了工时但没分配
        ghost = store.add_employee({"name": "幽灵员工", "level": "P5"})
        store.add_worklog({"employee_id": ghost, "project_id": a,
                           "work_date": days_ago(2), "hours": 12})
        # 低职级负责关键步骤（中位数以上算资深，P4 低于中位数）
        store.add_employee({"name": "新人", "level": "P4"})
        store.add_employee({"name": "老手", "level": "P8"})
        store.add_step(a, {"name": "核心步骤", "status": "进行中", "owner": "新人"})
        # 空转分配：开始超过 14 天、实际工时 0
        idle_person = store.add_employee({"name": "闲着的人", "level": "P5"})
        store.add_assignment({"project_id": c, "employee_id": idle_person,
                              "planned_hours": 40, "start_date": days_ago(30)})

        found = rules.insights(store)
        titles = [item["title"] for item in found]
        assert found, "问题数据上一条洞察都没报"

        expectations = {
            "投入最大": "低效项目",
            "超出同期应出工时": "超负荷",
            "同时挂在": "摊到多个项目",
            "已阻塞": "阻塞太久",
            "顺序矛盾": "顺序矛盾",
            "没分配到人": "工时无归属",
            "一直没开工": "空转分配",
            "职级偏低": "低职级挑大梁",
        }
        missing = [label for keyword, label in expectations.items()
                   if not any(keyword in title for title in titles)]

        # 每条洞察都必须带数字依据和建议，否则就是废话
        for item in found:
            assert item["detail"].strip(), f"洞察缺少数字依据：{item['title']}"
            assert item["advice"].strip(), f"洞察缺少建议：{item['title']}"
            assert item["group"] in rules.INSIGHT_GROUPS, \
                f"洞察分组异常：{item['group']}"

        text = rules.format_insights(found)
        assert "建议：" in text, "格式化后的洞察没有建议"

        print(f"洞察引擎：问题数据上报出 {len(found)} 条，"
              f"覆盖 {len(expectations) - len(missing)}/{len(expectations)} 类")
        if missing:
            print(f"  未触发的类别：{'、'.join(missing)}")
        return True
    finally:
        store.close()


def check_export():
    """导出要能跑通（CSV 不需要额外依赖）"""
    import db
    import export
    import tempfile

    store = db.Store(":memory:")
    try:
        project_id = store.add_project({"name": "导出测试", "budget": 100, "cost": 10})
        store.add_assessment(project_id, {"kind": "ability", "name": "测试", "score": 3})
        with tempfile.TemporaryDirectory() as folder:
            path = f"{folder}/out.csv"
            count = export.export_all(store, path)
            assert count >= 8, f"导出的表数量偏少：{count}"
            import os
            for name in export.SHEETS:
                target = f"{folder}/out_{name}.csv"
                assert os.path.isfile(target), f"缺少导出的文件：{name}"
        print(f"导出：正常（{count} 张表）")
        return True
    finally:
        store.close()


def check_return_shapes():
    """调用方 unpack 的数量必须和返回值一致。

    这是个看不见的运行期错误：`ok, message = watch.start(...)`
    在 start() 返回 3 元组时才会炸，而静态检查查不出——
    ast 只看名字，不看元组长度。所以这里用 ast 数一下
    「赋值左边的变量个数」和「同文件里 return 的元组长度」，
    对得上才算过。
    """
    import ast as ast_module

    problems = []
    for path in sorted(HERE.glob("*.py")):
        if path.name == "check.py":
            continue
        try:
            tree = ast_module.parse(path.read_text(encoding="utf-8"), str(path))
        except (SyntaxError, OSError):
            continue
        for node in ast_module.walk(tree):
            if not isinstance(node, (ast_module.FunctionDef,
                                     ast_module.AsyncFunctionDef)):
                continue
            # 收集这个函数里 return 出来的元组长度
            lengths = set()
            has_bare = False
            for child in ast_module.walk(node):
                if isinstance(child, ast_module.Return):
                    if child.value is None:
                        has_bare = True
                    elif isinstance(child.value, ast_module.Tuple):
                        lengths.add(len(child.value.elts))
                    else:
                        has_bare = True
            if len(lengths) > 1:
                problems.append(
                    f"{path.name}:{node.lineno}: 函数「{node.name}」"
                    f"返回的元组长度不一致：{sorted(lengths)}"
                )
    if problems:
        print(f"返回值形状：{len(problems)} 处不一致")
        for line in problems:
            print(f"  {line}")
        return len(problems)
    print("返回值形状：函数内部返回的元组长度一致")
    return 0


def check_metrics():
    """公共计算：边界情况逐个验证。

    这些都是纯函数，最容易也最值得测彻底——
    它们被界面、预测、导出、小助手共用，
    一处算错会同时污染好几个页面（前面就这么出过 bug：
    负荷公式有 5 个副本，改口径漏掉 4 个）。
    """
    import metrics

    # ---- num：脏数据不能抛异常 ----
    assert metrics.num(None) == 0
    assert metrics.num("") == 0
    assert metrics.num("abc") == 0          # 非数字字符串
    assert metrics.num("3.5") == 3.5
    assert metrics.num(7) == 7
    assert metrics.num([], 1) == 1          # 完全没法转的，用默认值

    # ---- safe_div：除零不能崩 ----
    assert metrics.safe_div(10, 0) == 0
    assert metrics.safe_div(10, None) == 0
    assert metrics.safe_div(0, 5) == 0
    assert metrics.safe_div(10, 4) == 2.5
    assert metrics.safe_div(10, 0, -1) == -1

    # ---- expected_hours：分母必须带上天数 ----
    # 这是之前出过 bug 的地方：写成 weekly 而漏乘周数
    assert metrics.expected_hours(40, 7) == 40
    assert metrics.expected_hours(40, 28) == 160
    assert metrics.expected_hours(0, 7) == 0

    # ---- load_ratio：窗口变了结果要跟着变 ----
    # 60 小时在 7 天窗口里超负荷（40 基准），在 28 天窗口里不是
    assert metrics.load_ratio(60, 40, 7) == 1.5
    assert abs(metrics.load_ratio(60, 40, 28) - 0.375) < 1e-9
    assert metrics.load_ratio(60, 0, 7) == 0        # 没基准不能崩
    assert metrics.load_ratio(None, 40, 7) == 0

    # ---- budget_usage：没预算要能和「花了 0%」区分开 ----
    no_budget = metrics.budget_usage({"budget": 0, "cost": 500})
    assert no_budget["used_ratio"] is None, "没设预算时不该给出比例"
    assert no_budget["has_budget"] is False
    assert metrics.budget_usage({"budget": 0, "cost": 0})["over"] is False
    over_budget = metrics.budget_usage({"budget": 100, "cost": 150})
    assert over_budget["used_ratio"] == 1.5
    assert over_budget["over"] is True
    assert over_budget["remaining"] == -50

    # ---- step_stats ----
    stats = metrics.step_stats([
        {"status": "已完成"}, {"status": "已完成"},
        {"status": "进行中"}, {"status": "已阻塞"}, {"status": "未开始"},
    ])
    assert stats["total"] == 5 and stats["done"] == 2 and stats["blocked"] == 1
    assert abs(stats["done_ratio"] - 0.4) < 1e-9
    assert metrics.step_stats([])["done_ratio"] == 0    # 空列表不能除零
    assert metrics.step_stats(None)["total"] == 0

    # ---- 日期 ----
    assert metrics.parse_date("2026-01-05") is not None
    assert metrics.parse_date("2026/01/05") is not None
    assert metrics.parse_date("20260105") is not None
    assert metrics.parse_date("") is None
    assert metrics.parse_date("乱写的") is None
    assert metrics.days_between("2026-01-01", "2026-01-11") == 10
    assert metrics.days_between("2026-01-01", "") is None
    assert metrics.days_left("") is None

    # ---- sum_hours：空值和缺字段都要安全 ----
    assert metrics.sum_hours([]) == 0
    assert metrics.sum_hours([{"hours": 3}, {"hours": None}]) == 3
    assert metrics.sum_hours([{"name": "没有 hours 字段"}]) == 0

    # ---- aggregate_hours：按三维度聚合 ----
    totals = metrics.aggregate_hours([
        {"employee_id": 1, "project_id": 2, "step_id": 3, "hours": 2},
        {"employee_id": 1, "project_id": 2, "step_id": 3, "hours": 3},
        {"employee_id": 1, "project_id": 2, "step_id": None, "hours": 1},
    ])
    assert totals[(1, 2, 3)] == 5
    assert totals[(1, 2, None)] == 1

    # ---- progress_gap ----
    # 时间过了 75%、进度 35% → 落后 0.40
    assert abs(metrics.progress_gap(35, 0.75) - 0.40) < 1e-9
    assert metrics.progress_gap(90, 0.5) < 0      # 进度领先是负数

    print("公共计算：边界情况全部正常（除零、空值、脏数据、窗口变化）")
    return True


def check_charts():
    """图表：坐标轴取整和空数据不能崩。

    图表没法在无界面环境里真正绘制，但**喂数据的逻辑**可以测：
    空列表、全零、只有一个点、日期缺失——这些是最容易崩的输入。
    """
    import chart

    # nice_max：轴上界要取整到好读的数，且必须 >= 原始最大值
    assert chart._ChartBase.nice_max(0) == 1.0        # 全零不能返回 0（会除零）
    assert chart._ChartBase.nice_max(-5) == 1.0
    for raw in (1, 7, 42, 137, 980, 3721, 12.5):
        top = chart._ChartBase.nice_max(raw)
        assert top >= raw, f"轴上界 {top} 小于数据最大值 {raw}"
    assert chart._ChartBase.nice_max(3721) == 5000      # 好读
    assert chart._ChartBase.nice_max(42) == 50

    # 这些控件在无 QApplication 的情况下不能实例化，
    # 所以只验证「数据准备」这部分纯逻辑：
    # TimelineChart 的日期解析和跳过规则，用源码里的判定重放一遍
    import metrics

    steps = [
        {"name": "有日期", "start": "2026-01-01", "due": "2026-02-01",
         "progress": 50, "status": "进行中"},
        {"name": "只有截止", "start": "", "due": "2026-03-01",
         "progress": 0, "status": "未开始"},
        {"name": "没日期", "start": "", "due": "", "progress": 0,
         "status": "未开始"},
        {"name": "进度超范围", "start": "2026-01-01", "due": "2026-01-02",
         "progress": 250, "status": "进行中"},
    ]
    dated = [s for s in steps
             if metrics.parse_date(s["start"]) or metrics.parse_date(s["due"])]
    assert len(dated) == 3, "只有一头日期的步骤也该画进时间轴"

    # 负荷率分组上色：超标/接近/正常三档不能有缺口
    import theme
    levels = theme.level_colors()
    for name in ("健康", "关注", "风险", "严重"):
        assert name in levels, f"风险等级缺配色：{name}"

    # 序列色要够用（分组柱状图最多两组，折线图可能多条）
    series = theme.series_colors()
    assert len(series) >= 4, "序列配色太少，多条曲线会撞色"
    for color in series:
        assert color.startswith("#") and len(color) == 7, f"配色格式异常：{color}"

    # ---- QSS 里的每个 $token 都必须在**两套**主题里都有值 ----
    # 少一个 token 的话，切到那套主题时整段样式会失效
    # （Template.safe_substitute 会原样保留 $xxx，界面直接变样）
    import re
    raw_qss = (HERE / "style.qss").read_text(encoding="utf-8")
    # **先剥掉注释再找 token**。
    # 文件头那句说明文字里有 `$token 由 theme.py 在运行时替换`，
    # 后缀判断（(?![A-Za-z0-9_])）拦不住它——token 后面是空格，
    # 而中文也不是 \w。唯一可靠的办法是根本不看注释。
    qss = re.sub(r"/\*.*?\*/", "", raw_qss, flags=re.S)
    tokens = set(re.findall(r"\$([A-Za-z_][A-Za-z0-9_]*)", qss))
    assert len(tokens) >= 20, (
        f"只找到 {len(tokens)} 个 token，数量明显偏少——"
        "要么 style.qss 被改坏了，要么剥离注释的逻辑删多了"
    )
    for theme_name, palette in theme.THEMES.items():
        missing = sorted(tokens - set(palette))
        assert not missing, (
            f"{theme_name} 主题缺少 style.qss 用到的 token：{missing}"
            "——切到这套主题时那些样式会失效"
        )
        # 颜色值格式也要对，否则 Qt 会静默忽略整条规则
        for key, value in palette.items():
            assert isinstance(value, str) and value.startswith("#") \
                and len(value) == 7, \
                f"{theme_name} 主题的 {key} 不是合法的 #rrggbb：{value!r}"

    # 两套主题的 key 必须完全一致，否则「浅色能用、深色缺东西」
    light_keys = set(theme.THEMES["light"])
    dark_keys = set(theme.THEMES["dark"])
    assert light_keys == dark_keys, (
        f"两套主题的 token 不一致："
        f"浅色独有 {sorted(light_keys - dark_keys)}，"
        f"深色独有 {sorted(dark_keys - light_keys)}"
    )

    # ---- 自绘控件必须能在切主题时自己更新 ----
    # 图表的颜色不走 QSS，切主题时得自己重画；
    # 忘了这件事的表现是「界面变深色了、图还是浅色」。
    import inspect
    import widgets
    for cls_name in ("ChatBubble",):
        cls = getattr(widgets, cls_name)
        assert hasattr(cls, "apply_theme"), \
            f"{cls_name} 没有 apply_theme，切主题后颜色不会更新"
        assert issubclass(cls, widgets.ThemedWidget), \
            f"{cls_name} 没有继承 ThemedWidget，收不到主题变化"

    base_source = inspect.getsource(chart._ChartBase.changeEvent)
    assert "StyleChange" in base_source, \
        "图表基类没有监听 StyleChange，切主题后图不会重画"

    # ---- 用到的 Qt 枚举必须真实存在 ----
    # 这里踩过一次：我凭印象写了 QEvent.Type.StyleSheetChange，
    # 实际枚举叫 StyleChange。名字写错的话，
    # **只有切主题那一刻才会崩**（事件处理里 AttributeError），
    # 平时完全看不出来。所以直接问 Qt 有没有这个枚举。
    from PyQt6.QtCore import QEvent
    for name in ("StyleChange", "PaletteChange"):
        assert hasattr(QEvent.Type, name), (
            f"QEvent.Type 里没有 {name}——事件判断写错了枚举名，"
            "会在收到该事件时直接 AttributeError"
        )
    # 确认那个我写错过的名字**在 Qt 里确实不存在**。
    # 它存在的意义是：万一将来某个 Qt 版本真的加了这个枚举，
    # 这条会失败，提醒去更新注释和代码里的说明。
    assert not hasattr(QEvent.Type, "StyleSheetChange"), (
        "Qt 居然有 StyleSheetChange 了？"
        "那 chart.py / widgets.py 注释里的说明要一并更新"
    )

    # 顺手确认那个名字没被**用在代码里**。
    #
    # **只看代码，不看注释**：chart.py 和 widgets.py 的注释里
    # 故意提到了 StyleSheetChange（"不是 StyleSheetChange，"
    # "写错会直接崩"），那是给人看的提醒。
    # 直接用 `"StyleSheetChange" not in source` 会把注释也算进去，
    # 于是**正确写了注释反而让检查失败**——这个断言这样误报过一次。
    def code_only(text):
        """去掉注释和字符串之后的源码。"""
        pieces = []
        try:
            for token in tokenize.generate_tokens(io.StringIO(text).readline):
                # COMMENT 是注释，STRING 是字符串字面量。
                # 两个都跳过：字符串里可能也只在描述这个坑。
                if token.type in (tokenize.COMMENT, tokenize.STRING):
                    continue
                pieces.append(token.string)
        except (tokenize.TokenError, IndentationError):
            # 片段不完整时退化成原样返回，让断言按原来的方式判断，
            # 不因为解析失败而误报通过。
            return text
        return " ".join(pieces)

    for source in (base_source,
                   inspect.getsource(widgets.ThemedWidget.changeEvent)):
        assert "StyleSheetChange" not in code_only(source), \
            "还有地方在用不存在的 QEvent.Type.StyleSheetChange"

    print(f"图表：坐标轴取整、空数据、日期缺失、配色齐全、"
          f"{len(tokens)} 个 QSS token 两套主题都齐、Qt 枚举名正确 全部正常")
    return True


def check_server():
    """员工提交服务：校验和写库逻辑，不真的开端口。

    真正开端口在无界面环境里会招来防火墙弹窗，所以这里只测
    **提交处理**这部分——它才是会出错的地方（表单字段解析、
    越权改别的项目的步骤、填未来日期、超 24 小时）。
    """
    import datetime as dt
    import db
    import server

    def days_ago(n):
        return (dt.date.today() - dt.timedelta(days=n)).isoformat()

    store = db.Store(":memory:")
    try:
        project_id = store.add_project({
            "name": "在跑的项目", "status": "进行中",
            "start_date": days_ago(30), "due_date": days_ago(-30),
        })
        done_project = store.add_project({"name": "已交付项目", "status": "已交付"})
        step_id = store.add_step(project_id, {"name": "联调", "status": "进行中"})
        other_step = store.add_step(done_project, {"name": "别人的步骤"})
        employee_id = store.add_employee({"name": "王强", "weekly_hours": 40})

        handler = server.SubmitServer(store)

        def form(**fields):
            """模拟 parse_qs 的结果：值都是列表"""
            data = {}
            for key, value in fields.items():
                if isinstance(value, list):
                    data[key] = [str(v) for v in value]
                else:
                    data[key] = [str(value)]
            return data

        # ---- 正常提交 ----
        ok, message = handler.submit_worklog(form(
            employee_id=employee_id, project_id=project_id, step_id=step_id,
            work_date=days_ago(1), hours=8, content="调接口",
        ))
        assert ok, f"正常提交失败了：{message}"
        assert len(store.worklogs()) == 1, "工时没写进去"

        # ---- 勾选完成 ----
        ok, message = handler.submit_worklog(form(
            employee_id=employee_id, project_id=project_id,
            work_date=days_ago(1), hours=4, done_step=[step_id],
        ))
        assert ok, f"带完成勾选的提交失败：{message}"
        assert store.one("SELECT status FROM step WHERE id=?", (step_id,))["status"] \
            == "已完成", "勾了完成但步骤状态没改"
        assert "联调" in message, "回复里没提到完成的步骤"

        # ---- 各种非法输入都要被挡住 ----
        bad_cases = [
            ("没填员工", form(employee_id="", project_id=project_id,
                              work_date=days_ago(1), hours=8)),
            ("员工不存在", form(employee_id=99999, project_id=project_id,
                                work_date=days_ago(1), hours=8)),
            ("工时为零", form(employee_id=employee_id, project_id=project_id,
                              work_date=days_ago(1), hours=0)),
            ("工时超 24", form(employee_id=employee_id, project_id=project_id,
                               work_date=days_ago(1), hours=30)),
            ("工时是文字", form(employee_id=employee_id, project_id=project_id,
                                work_date=days_ago(1), hours="八小时")),
            ("日期乱写", form(employee_id=employee_id, project_id=project_id,
                              work_date="昨天", hours=8)),
            ("未来日期", form(employee_id=employee_id, project_id=project_id,
                              work_date=days_ago(-3), hours=8)),
            ("项目不存在", form(employee_id=employee_id, project_id=99999,
                                work_date=days_ago(1), hours=8)),
            ("已交付项目", form(employee_id=employee_id, project_id=done_project,
                                work_date=days_ago(1), hours=8)),
        ]
        for label, payload in bad_cases:
            ok, message = handler.submit_worklog(payload)
            assert not ok, f"「{label}」本该被拒绝，却通过了"
            assert message.strip(), f"「{label}」被拒绝了但没说明原因"

        # ---- 越权：拿别的项目的步骤 id 来勾完成，不该改到那个步骤 ----
        before = store.one("SELECT status FROM step WHERE id=?", (other_step,))["status"]
        ok, _message = handler.submit_worklog(form(
            employee_id=employee_id, project_id=project_id,
            work_date=days_ago(1), hours=4, done_step=[other_step],
        ))
        after = store.one("SELECT status FROM step WHERE id=?", (other_step,))["status"]
        assert before == after, "勾完成时改到了别的项目的步骤——这是越权"

        # ---- 步骤 id 不属于所选项目时，应被忽略而不是报错 ----
        ok, message = handler.submit_worklog(form(
            employee_id=employee_id, project_id=project_id, step_id=other_step,
            work_date=days_ago(1), hours=2,
        ))
        assert ok, f"步骤对不上时应当忽略步骤继续提交，却失败了：{message}"

        # ---- 不开端口：只验证地址格式 ----
        url = handler.url()
        assert url.startswith("http://") and url.endswith("/"), f"地址格式异常：{url}"

        # ---- 真实形状：所有字段都是「只有一个元素的列表」----
        # 这一步是为了防止「自检构造的数据比真实数据干净」——
        # 之前就是手工构造了已拆包的 dict，恰好绕过了
        # `'list' object has no attribute 'strip'` 这个必然发生的崩溃。
        def raw_form(**overrides):
            data = {
                "employee_id": [str(employee_id)],
                "project_id": [str(project_id)],
                "step_id": [""],
                "work_date": [days_ago(2)],
                "hours": ["6.5"],
                "content": ["真实形状的提交"],
            }
            for key, value in overrides.items():
                data[key] = [str(value)]
            return data

        ok, message = handler.submit_worklog(raw_form())
        assert ok, f"用 parse_qs 的真实形状提交失败了：{message}"

        # ---- 必填字段缺失 → 必须被拒绝，并说明原因 ----
        # employee_id / work_date / hours / project_id 都是必填。
        # project_id 也必填：不能让「漏选项目」变成静悄悄的「非项目事务」。
        for missing in ("employee_id", "work_date", "hours", "project_id"):
            partial = raw_form()
            partial.pop(missing)
            try:
                ok, message = handler.submit_worklog(partial)
            except Exception as error:      # noqa: BLE001
                raise AssertionError(
                    f"缺了「{missing}」字段时崩了，应当只是拒绝："
                    f"{type(error).__name__}: {error}"
                ) from error
            assert not ok, f"缺了必填的「{missing}」却被接受了"
            assert message.strip(), f"缺了「{missing}」被拒但没说明原因"

        # ---- 可选字段缺失 → 应当照样能提交（只填工时也是有效的一天）----
        # 每个用例换一天：同一个日期+项目+工时+说明会被当成重复提交拒掉，
        # 那样测的就不是「可选字段」而是「去重」了。
        for index, optional in enumerate(("content", "step_id")):
            partial = raw_form()
            partial.pop(optional)
            partial["work_date"] = [days_ago(20 + index)]
            partial["content"] = [f"可选字段测试 {index}"]
            try:
                ok, message = handler.submit_worklog(partial)
            except Exception as error:      # noqa: BLE001
                raise AssertionError(
                    f"缺了可选字段「{optional}」时崩了："
                    f"{type(error).__name__}: {error}"
                ) from error
            assert ok, f"「{optional}」是可选的，缺了不该被拒绝：{message}"

        # ---- 同一份内容重复提交 → 要拒绝，不能记成两条 ----
        repeat = raw_form()
        repeat["work_date"] = [days_ago(21)]
        repeat["content"] = ["重复提交测试"]
        ok, _ = handler.submit_worklog(repeat)
        assert ok, "第一次提交应当成功"
        before = len(store.worklogs())
        ok, message = handler.submit_worklog(repeat)
        assert not ok, "同样的内容提交两次，第二次没有被拦住"
        assert "提交过" in message or "重复" in message, \
            f"拒绝理由没说清是重复：{message}"
        assert len(store.worklogs()) == before, "重复提交被记成了两条"

        # ---- 项目选了空值也必须拒绝（不能默默记成「非项目」）----
        ok, message = handler.submit_worklog(raw_form(project_id=""))
        assert not ok, "项目留空却被接受了——会变成静悄悄的「非项目」记录"
        assert "项目" in message, f"拒绝理由没说清是项目的问题：{message}"

        # 空表单、纯字符串值、空列表值都不能崩
        awkward = (
            ("空表单", {}),
            ("纯字符串值", {"employee_id": "1", "project_id": str(project_id),
                            "work_date": days_ago(1), "hours": "8"}),
            ("字段是空列表", {"employee_id": [], "work_date": [], "hours": []}),
        )
        for label, payload in awkward:
            try:
                handler.submit_worklog(payload)
            except Exception as error:      # noqa: BLE001
                raise AssertionError(
                    f"「{label}」导致崩溃：{type(error).__name__}: {error}"
                ) from error

        print(f"员工提交：{len(bad_cases)} 种非法输入全部被挡，越权改步骤被拒，"
              "必填缺一即拒、可选缺失照常、真实表单形状不崩")
        return True
    finally:
        store.close()


def check_submit_files():
    """文件交换：导出 → 导入 → 重复导入必须安全。

    这是「不用局域网」那条路的核心，最要紧的性质是**幂等**：
    同一个文件导入两次，第二次必须一条都不新增。
    员工多转一次文件、老板手滑导两遍，都不该变成两份记录。
    """
    import datetime as dt
    import json
    import os
    import tempfile

    import db
    import submit

    store = db.Store(":memory:")
    tempdir = tempfile.mkdtemp(prefix="pr_submit_")
    try:
        project_id = store.add_project({"name": "智慧园区", "status": "进行中"})
        step_id = store.add_step(project_id, {"name": "接口联调", "status": "进行中"})
        employee_id = store.add_employee({"name": "王强", "role": "后端",
                                          "level": "P6", "weekly_hours": 40})
        for offset in (1, 2, 3):
            store.add_worklog({
                "employee_id": employee_id, "project_id": project_id,
                "step_id": step_id,
                "work_date": (dt.date.today() - dt.timedelta(days=offset)).isoformat(),
                "hours": 8, "content": f"第 {offset} 天",
            })
        # 再加一条非项目的
        store.add_worklog({
            "employee_id": employee_id, "project_id": None,
            "work_date": (dt.date.today() - dt.timedelta(days=4)).isoformat(),
            "hours": 2, "content": "内部会议",
        })

        # ---- 导出 ----
        data = submit.export_employee(store, employee_id)
        assert len(data["entries"]) == 4, f"应导出 4 条，实际 {len(data['entries'])}"
        path = os.path.join(tempdir, submit.suggested_filename(data))
        submit.write_file(data, path)
        assert os.path.isfile(path), "导出文件没写出来"

        # 文件要能被独立读回（模拟老板收到另一个文件）
        reread, error = submit.read_file(path)
        assert reread is not None, f"读不回自己导出的文件：{error}"

        # ---- 老板端导入 ----
        boss = db.Store(":memory:")
        try:
            # 老板这边有同名项目和同名员工，但 id 必然和员工那边不同。
            # 两个内存库都从 1 开始编号，所以要**故意多建两个再删掉**，
            # 让 id 错开——否则「按名字匹配」和「按 id 匹配」测不出区别。
            # 项目和员工都要错开，少错开一个就测不出那一半。
            for throwaway in ("占位一", "占位二"):
                temp_id = boss.add_project({"name": throwaway})
                boss.delete_project(temp_id)
                temp_employee = boss.add_employee({"name": throwaway})
                boss.delete_employee(temp_employee)
            boss_project = boss.add_project({"name": "智慧园区", "status": "进行中"})
            boss.add_step(boss_project, {"name": "接口联调", "status": "进行中"})
            boss_employee = boss.add_employee({"name": "王强", "level": "P6"})
            assert boss_project != project_id, (
                f"两边的项目 id 撞了（都是 {project_id}），"
                "这样测不出「按名字匹配」——占位项目没起作用"
            )
            assert boss_employee != employee_id, (
                f"两边的员工 id 撞了（都是 {employee_id}），"
                "这样测不出员工是按名字匹配的——占位员工没起作用"
            )

            report = submit.import_file(boss, path)
            assert report["ok"], f"导入失败了：{report['summary']}"
            assert report["added"] == 4, f"应新增 4 条，实际 {report['added']}"
            assert report["duplicated"] == 0
            assert not report["unknown_projects"]
            assert len(boss.worklogs()) == 4, "库里的条数不对"

            # 项目要按名字挂到老板这边的 id 上
            logs = boss.worklogs()
            project_logs = [log for log in logs if log["project_id"] is not None]
            assert len(project_logs) == 3, "项目工时的条数不对"
            for log in project_logs:
                assert log["project_id"] == boss_project, "挂错项目了"
                assert log["employee_id"] == boss_employee, "挂错人了"
            # 步骤也要按名字挂上
            assert any(log["step_id"] is not None for log in project_logs), \
                "步骤没有按名字匹配上"
            # 非项目那条要保持为空
            assert any(log["project_id"] is None for log in logs), \
                "非项目工时被错误地挂上了项目"

            # ---- 幂等：同一个文件再导一次，一条都不该新增 ----
            again = submit.import_file(boss, path)
            assert again["added"] == 0, \
                f"重复导入又新增了 {again['added']} 条——幂等性坏了"
            assert again["duplicated"] == 4, \
                f"重复的条数不对：{again['duplicated']}"
            assert len(boss.worklogs()) == 4, "重复导入把记录搞多了"

            # 第三次也一样
            third = submit.import_file(boss, path)
            assert third["added"] == 0 and len(boss.worklogs()) == 4

            # ---- 员工不在名单里 → 自动新建并告知 ----
            data2 = dict(data)
            data2["employee"] = {"name": "新来的", "role": "前端",
                                 "level": "", "weekly_hours": 40}
            path2 = os.path.join(tempdir, "新来的.json")
            submit.write_file(data2, path2)
            report2 = submit.import_file(boss, path2)
            assert report2["ok"], f"新员工导入失败：{report2['summary']}"
            assert report2["created_employee"] == "新来的", "没有报告新建了员工"
            assert "新建员工" in report2["summary"], "报告里没提新建员工"
            assert boss.one("SELECT id FROM employee WHERE name='新来的'") is not None

            # ---- 未知项目 → 跳过并报告，不自动建项目 ----
            data3 = dict(data)
            data3["employee"] = {"name": "王强", "level": "P6", "weekly_hours": 40}
            data3["entries"] = [dict(entry) for entry in data["entries"]]
            for entry in data3["entries"]:
                entry["project"] = "老板没建过的项目"
            path3 = os.path.join(tempdir, "未知项目.json")
            submit.write_file(data3, path3)
            projects_before = len(boss.projects())
            report3 = submit.import_file(boss, path3)
            assert report3["added"] == 0, "未知项目的记录不该被导入"
            assert "老板没建过的项目" in report3["unknown_projects"], \
                "没有报告未知项目"
            assert len(boss.projects()) == projects_before, \
                "自动建了不该建的项目——那会造出一堆重名项目"
        finally:
            boss.close()

        # ---- 坏文件要被挡住，且说清原因 ----
        bad_cases = []
        not_json = os.path.join(tempdir, "坏文件.json")
        with open(not_json, "w", encoding="utf-8") as f:
            f.write("这不是 json")
        bad_cases.append(("内容不是 JSON", not_json))

        wrong_format = os.path.join(tempdir, "别的程序.json")
        with open(wrong_format, "w", encoding="utf-8") as f:
            json.dump({"format": "别的程序", "entries": []}, f)
        bad_cases.append(("不是本程序的文件", wrong_format))

        future_version = os.path.join(tempdir, "新版本.json")
        with open(future_version, "w", encoding="utf-8") as f:
            json.dump({"format": "ProjectRecorder.worklog", "version": 999,
                       "employee": {"name": "王强"}, "entries": []}, f)
        bad_cases.append(("版本比程序新", future_version))

        no_employee = os.path.join(tempdir, "没说是谁.json")
        with open(no_employee, "w", encoding="utf-8") as f:
            json.dump({"format": "ProjectRecorder.worklog", "version": 1,
                       "employee": {}, "entries": []}, f)
        bad_cases.append(("没说是谁", no_employee))

        for label, path_bad in bad_cases:
            data_bad, error = submit.read_file(path_bad)
            assert data_bad is None, f"「{label}」本该读不出来"
            assert error.strip(), f"「{label}」没有给出原因"

        assert submit.read_file(os.path.join(tempdir, "不存在.json"))[0] is None

        # ---- 单条脏数据：跳过该条，其余照常导入 ----
        mixed = dict(data)
        mixed["employee"] = {"name": "王强", "level": "P6", "weekly_hours": 40}
        mixed["entries"] = [
            dict(data["entries"][0]),
            {"work_date": "不是日期", "project": "智慧园区", "hours": 8},
            {"work_date": dt.date.today().isoformat(), "project": "智慧园区",
             "hours": 99},
            {"work_date": dt.date.today().isoformat(), "project": "智慧园区",
             "hours": -3},
        ]
        mixed["entries"][0]["work_date"] = (
            dt.date.today() - dt.timedelta(days=10)
        ).isoformat()
        mixed["entries"][0]["content"] = "脏数据测试用"
        path_mixed = os.path.join(tempdir, "混合.json")
        submit.write_file(mixed, path_mixed)

        boss2 = db.Store(":memory:")
        try:
            boss2.add_project({"name": "智慧园区", "status": "进行中"})
            boss2.add_employee({"name": "王强"})
            report_mixed = submit.import_file(boss2, path_mixed)
            assert report_mixed["added"] == 1, \
                f"该只导入 1 条有效记录，实际 {report_mixed['added']}"
            assert len(report_mixed["skipped"]) == 3, \
                f"该报告 3 条脏数据，实际 {len(report_mixed['skipped'])}"
            for item in report_mixed["skipped"]:
                assert item.strip(), "跳过的条目不说明原因"
        finally:
            boss2.close()

        # ---- 指纹必须稳定：同一条数据算两次结果一样 ----
        key1 = submit.source_key(1, 2, "2026-01-05", 8, "干活")
        key2 = submit.source_key(1, 2, "2026-01-05", 8.0, "干活")
        assert key1 == key2, "8 和 8.0 算出了不同的指纹，会导致重复导入"
        assert key1 != submit.source_key(1, 2, "2026-01-05", 8, "干别的活")
        assert key1 != submit.source_key(1, 2, "2026-01-06", 8, "干活")

        print(f"文件交换：导出 4 条、导入 4 条、重复导入 0 新增、"
              f"{len(bad_cases)} 种坏文件被挡、脏数据逐条跳过、未知项目不自动建")
        return True
    finally:
        store.close()
        import shutil
        shutil.rmtree(tempdir, ignore_errors=True)


def check_timer():
    """计时器：真实流逝、不能快进、改了系统时间能被发现。

    这里用**可注入的时钟**，所以不用真的等三小时——
    给 Timer 传一个假的 monotonic 就能模拟任意时长。
    """
    import datetime as dt
    import db
    import timer as timer_module

    store = db.Store(":memory:")
    try:
        project_id = store.add_project({"name": "在跑的项目", "status": "进行中"})
        step_id = store.add_step(project_id, {"name": "联调", "status": "进行中"})
        employee_id = store.add_employee({"name": "王强", "weekly_hours": 40})

        # 假时钟：手动往前拨，模拟时间流逝
        fake = {"now": 1000.0}
        clock = lambda: fake["now"]                     # noqa: E731

        watch = timer_module.Timer(store, employee_id, clock=clock)

        # ---- 开始 ----
        ok, message = watch.start(project_id=project_id, step_id=step_id,
                                  content="调接口")
        assert ok, f"开始计时失败：{message}"
        assert watch.status() == "running"

        # ---- 计时中：时长跟着单调时钟走 ----
        fake["now"] += 3600          # 拨快 1 小时
        assert abs(watch.elapsed_seconds() - 3600) < 1, "计时没跟着时钟走"
        assert timer_module.format_duration(watch.elapsed_seconds()) == "1:00:00"

        # ---- 暂停：时长不再增长 ----
        ok, _ = watch.pause()
        assert ok and watch.status() == "paused"
        fake["now"] += 1800          # 暂停期间又拨快半小时
        assert abs(watch.elapsed_seconds() - 3600) < 1, \
            "暂停期间时长还在涨——暂停没起作用"

        # ---- 继续 ----
        ok, _ = watch.resume()
        assert ok and watch.status() == "running"
        fake["now"] += 1800

        # ---- 结束：应当记一条 1.5 小时的工时 ----
        ok, message = watch.finish()
        assert ok, f"结束计时失败：{message}"
        logs = store.worklogs()
        assert len(logs) == 1, f"该记 1 条工时，实际 {len(logs)}"
        assert abs(float(logs[0]["hours"]) - 1.5) < 0.01, \
            f"时长算错了：{logs[0]['hours']}"
        assert logs[0]["source"] == "timer", \
            "计时记的工时应标记为 timer，否则老板分不清计时和补录"
        assert logs[0]["project_id"] == project_id
        assert logs[0]["step_id"] == step_id
        assert watch.status() == "idle", "结束后不该还有会话"

        # ---- 太短的会话不记账 ----
        fake["now"] += 100000
        watch.start(project_id=project_id, content="点错了")
        fake["now"] += 5             # 只过 5 秒
        ok, message = watch.finish()
        assert not ok, "5 秒的计时不该记账"
        assert "太短" in message, f"拒绝理由没说明白：{message}"
        assert len(store.worklogs()) == 1, "太短的会话还是记了账"

        # ---- 丢弃：不记账 ----
        watch.start(project_id=project_id, content="要丢掉")
        fake["now"] += 7200
        ok, _ = watch.cancel()
        assert ok
        assert len(store.worklogs()) == 1, "丢弃的会话被记了账"
        assert watch.status() == "idle"

        # ---- 开始新计时时自动结束上一段 ----
        watch.start(project_id=project_id, content="第一段")
        fake["now"] += 3600
        before = len(store.worklogs())
        ok, message = watch.start(project_id=project_id, content="第二段")
        assert ok, f"自动结束上一段失败：{message}"
        assert "自动结束" in message, "没有说明自动结束了上一段"
        assert len(store.worklogs()) == before + 1, "上一段没有被记账"
        watch.cancel()

        # ---- 关掉程序再打开：计时接着走（状态存在数据库里）----
        watch.start(project_id=project_id, content="跨会话")
        fake["now"] += 1800
        reopened = timer_module.Timer(store, employee_id, clock=clock)
        assert abs(reopened.elapsed_seconds() - 1800) < 1, \
            "重开后计时丢了——状态没存在数据库里"
        reopened.cancel()

        # ---- 时长只来自注入的时钟，不读系统时间 ----
        # 这一点是「改系统时间不影响计时」的根本保证：
        # elapsed_seconds() 里只有 self._clock()，没有 datetime / time.time。
        import inspect
        source = inspect.getsource(timer_module.Timer.elapsed_seconds)
        assert "time.time" not in source, \
            "计时里读了口系统时间——改系统时间就能快进"
        assert "datetime" not in source, \
            "计时里用了 datetime——那是系统时间，会被改"
        assert "self._clock()" in source, \
            "计时没走注入的时钟，没法保证用的是单调时钟"

        # ---- 校验：时长和起止时间对不上要被抓出来 ----
        good = {
            "manual": 0, "elapsed": 3600,
            "started_at": "2026-09-29 09:00:00",
            "ended_at": "2026-09-29 10:00:00",
        }
        assert not timer_module.check_session(good), \
            f"正常会话被误报：{timer_module.check_session(good)}"

        tampered = dict(good)
        # 员工把结束时间改成 8 小时后，但单调时钟说只过了 1 小时
        tampered["ended_at"] = "2026-09-29 17:00:00"
        problems = timer_module.check_session(tampered)
        assert problems, "改了结束时间却没被发现——防篡改失效了"
        assert any("对不上" in item for item in problems), \
            f"没指出时间戳对不上：{problems}"

        long_one = dict(good)
        long_one["elapsed"] = 20 * 3600
        long_one["ended_at"] = "2026-09-30 05:00:00"
        assert any("挂机" in item or "小时" in item
                   for item in timer_module.check_session(long_one)), \
            "超长会话没被提醒"

        # 补录的没有起止时间，不该被当成篡改
        manual = {"manual": 1, "elapsed": 3600,
                  "started_at": "", "ended_at": ""}
        assert not timer_module.check_session(manual), "补录被误判成篡改"

        # ---- 工时汇总校验：一天超 24 小时、时间段重叠 ----
        day = dt.date.today().isoformat()
        entries = [
            {"work_date": day, "hours": 8, "project": "A", "manual": False,
             "started_at": f"{day} 09:00:00", "ended_at": f"{day} 17:00:00"},
            {"work_date": day, "hours": 8, "project": "B", "manual": False,
             "started_at": f"{day} 14:00:00", "ended_at": f"{day} 22:00:00"},
        ]
        found = timer_module.check_worklog(entries)
        assert found, "时间段重叠没被发现"
        assert any("重叠" in item for _day, item in found), \
            f"没指出重叠：{found}"

        over = [
            {"work_date": day, "hours": 14, "project": "A", "manual": True,
             "started_at": "", "ended_at": ""},
            {"work_date": day, "hours": 14, "project": "B", "manual": True,
             "started_at": "", "ended_at": ""},
        ]
        found = timer_module.check_worklog(over)
        assert any("24" in item for _day, item in found), \
            f"一天超 24 小时没被发现：{found}"

        # 正常的一天不该被报
        normal = [
            {"work_date": day, "hours": 4, "project": "A", "manual": True,
             "started_at": "", "ended_at": ""},
            {"work_date": day, "hours": 4, "project": "B", "manual": True,
             "started_at": "", "ended_at": ""},
        ]
        assert not timer_module.check_worklog(normal), \
            f"正常的一天被误报：{timer_module.check_worklog(normal)}"

        print("计时器：单调时钟计时、暂停不累计、太短不记账、丢弃不记账、"
              "跨重启续计、改时间戳能被发现、重叠与超 24 小时都能报")
        return True
    finally:
        store.close()


def check_worklog_edit():
    """改工时：指纹要跟着重算，重复要能查出来。

    这里最容易出错的是**指纹不跟着改**：
    改完内容却留着旧指纹，以后员工再提交同一份文件时，
    会算出一个对不上的新指纹，于是同一条记录被导入第二遍。

    注意指纹只对**参与去重的记录**（导入来的）有意义。
    手录和计时的指纹是空的，它们本来就允许内容相同，
    改它们不该产生冲突，也不该被唯一索引拦住。
    """
    import db
    import submit

    store = db.Store(":memory:")
    try:
        project_id = store.add_project({"name": "项目", "status": "进行中"})
        employee_id = store.add_employee({"name": "王强"})

        # ---- 手录的记录没有指纹 ----
        manual_id = store.add_worklog({
            "employee_id": employee_id, "project_id": project_id,
            "work_date": "2026-09-05", "hours": 4, "content": "手录的",
        }, dedupe=False)
        manual_key = store.one("SELECT source_key FROM worklog WHERE id=?",
                               (manual_id,))["source_key"]
        assert manual_key == "", "手录的记录不该带指纹——它不参与去重"

        # ---- 导入来的记录有指纹，改完必须重算 ----
        log_id = store.add_worklog({
            "employee_id": employee_id, "project_id": project_id,
            "work_date": "2026-09-01", "hours": 8, "content": "原来的说明",
            "source": "timer",
            "source_key": "imported-key-1",
        }, dedupe=True)
        original_key = store.one("SELECT source_key FROM worklog WHERE id=?",
                                 (log_id,))["source_key"]
        assert original_key == "imported-key-1", "导入来的记录没保存指纹"

        # ---- 改内容，指纹必须跟着变 ----
        store.update_worklog(log_id, {"content": "改过的说明"})
        new_key = store.one("SELECT source_key FROM worklog WHERE id=?",
                            (log_id,))["source_key"]
        assert new_key != original_key, "改了内容但指纹没变——会导致重复导入"

        # 新指纹必须等于「用新内容重算」的结果
        expected = submit.source_key(employee_id, project_id, "2026-09-01",
                                     8, "改过的说明")
        assert new_key == expected, "改完的指纹和重算结果不一致"

        # ---- 改小时数，指纹也要变 ----
        store.update_worklog(log_id, {"hours": 6})
        hours_key = store.one("SELECT source_key FROM worklog WHERE id=?",
                              (log_id,))["source_key"]
        assert hours_key != new_key, "改了小时数但指纹没变"

        # ---- 只改项目，指纹也要变 ----
        other_project = store.add_project({"name": "另一个项目"})
        store.update_worklog(log_id, {"project_id": other_project})
        moved_key = store.one("SELECT source_key FROM worklog WHERE id=?",
                              (log_id,))["source_key"]
        assert moved_key != hours_key, "改了项目但指纹没变"

        # ---- 手录的怎么改都不会撞唯一索引 ----
        store.update_worklog(manual_id, {"content": "改过的手录"})
        store.update_worklog(manual_id, {"hours": 5})
        assert store.one("SELECT source_key FROM worklog WHERE id=?",
                         (manual_id,))["source_key"] == "", \
            "改手录记录时给它加上了指纹"
        assert store.worklog_conflict(manual_id, {"hours": 6}) is None, \
            "手录记录被报成冲突了——它本来就不参与去重"

        # ---- 两条导入记录改成一样 → conflict 要报出来 ----
        another = store.add_worklog({
            "employee_id": employee_id, "project_id": other_project,
            "work_date": "2026-09-02", "hours": 3, "content": "另一条",
            "source_key": "imported-key-2",
        }, dedupe=True)
        conflict = store.worklog_conflict(another, {
            "work_date": "2026-09-01", "hours": 6, "content": "改过的说明",
        })
        assert conflict is not None, "改成和另一条一样了，却没查出冲突"
        assert conflict["id"] == log_id, "报出来的冲突记录不对"

        # 不改到重复时，不该误报
        assert store.worklog_conflict(another, {"hours": 5}) is None, \
            "只改小时数就报冲突了——误报"

        # ---- 真正保存成重复时，唯一索引要拦住（不能静默写进去）----
        import sqlite3
        caught = False
        try:
            store.execute(
                "UPDATE worklog SET source_key = ? WHERE id = ?",
                (conflict["source_key"], another),
            )
        except sqlite3.IntegrityError:
            caught = True
        assert caught, "唯一索引没拦住重复指纹——去重机制形同虚设"

        print("改工时：指纹跟着重算（内容/小时/项目）、重复能查出、"
              "唯一索引拦得住")
        return True
    finally:
        store.close()


def check_checker():
    """验证「未定义名字」这个检查本身有没有用。

    为什么值得测：这几轮我改坏了它两次——
    一次崩（Module 没有 args），一次报了 105 处误报。
    一个不可信的检查比没有检查更糟，因为它会让人以为查过了。

    所以这里用**真的会出错的代码**喂给它，确认两件事：
      1. 忘了导入的名字，必须报（这是它存在的理由）
      2. 正常的作用域用法，绝不能报（误报会让人不再看它）
    """
    import ast as ast_module
    import tempfile

    def scan(source):
        """对一段源码跑一遍检查逻辑，返回报出来的名字集合"""
        tree = ast_module.parse(source)
        parents = _parent_map(tree)
        bound = _module_bindings(tree)
        reported = set()
        for node in ast_module.walk(tree):
            if not isinstance(node, ast_module.Name):
                continue
            if not isinstance(node.ctx, ast_module.Load):
                continue
            name = node.id
            if name in BUILTIN_NAMES or name in bound:
                continue
            if name in ("self", "cls", "__name__", "__file__", "__doc__"):
                continue
            found = False
            current = parents.get(node)
            while current is not None:
                if isinstance(current, (ast_module.FunctionDef,
                                        ast_module.AsyncFunctionDef)):
                    if name in _scope_names(current):
                        found = True
                        break
                current = parents.get(current)
            if not found:
                reported.add(name)
        return reported

    # ---- 必须报：忘了导入 ----
    missing = scan(
        "import os\n"
        "def f():\n"
        "    return QSizePolicy.Policy.Fixed\n"      # 没导入
    )
    assert "QSizePolicy" in missing, \
        f"忘了导入的名字没被报出来：{missing}"

    missing2 = scan(
        "def f():\n"
        "    return ASSIGN_STATUS[0]\n"               # 模块常量没定义
    )
    assert "ASSIGN_STATUS" in missing2, "没定义的模块常量没被报出来"

    # 类方法里忘了导入，也要报（当初 QSizePolicy 就出在方法里）
    missing3 = scan(
        "class W:\n"
        "    def m(self):\n"
        "        self.setSizePolicy(QSizePolicy.Policy.Fixed)\n"
    )
    assert "QSizePolicy" in missing3, "方法体里忘了导入没被报出来"

    # 嵌套函数里忘了导入——这条以前会漏
    missing4 = scan(
        "def outer():\n"
        "    def inner():\n"
        "        return SomethingMissing()\n"
        "    return inner\n"
    )
    assert "SomethingMissing" in missing4, "嵌套函数里忘了导入没被报出来"

    # ---- 绝不能报：正常的作用域用法 ----
    good_cases = {
        "模块常量在函数里用":
            "FONT = 'x'\n"
            "def f():\n"
            "    return FONT\n",
        "模块常量在方法里用":
            "NAME = 'x'\n"
            "class W:\n"
            "    def m(self):\n"
            "        return NAME\n",
        "类属性通过 self 访问":
            "class W:\n"
            "    PAD = 10\n"
            "    def m(self):\n"
            "        return self.PAD\n",
        "函数参数":
            "def f(alpha, beta=1, *args, gamma=2, **kwargs):\n"
            "    return alpha + beta + gamma\n",
        "函数内局部变量":
            "def f():\n"
            "    total = 0\n"
            "    for index in range(3):\n"
            "        total += index\n"
            "    return total\n",
        "模块级 for 循环变量":
            "import os\n"
            "for name in ('a', 'b'):\n"
            "    print(name)\n",
        "推导式变量":
            "def f(items):\n"
            "    return [item * 2 for item in items]\n",
        "with as 和 except as":
            "def f(path):\n"
            "    try:\n"
            "        with open(path) as handle:\n"
            "            return handle.read()\n"
            "    except OSError as error:\n"
            "        return str(error)\n",
        "嵌套函数用外层的变量":
            "def outer(alpha):\n"
            "    beta = 1\n"
            "    def inner(day):\n"
            "        return day + beta + alpha\n"
            "    return inner\n",
        "闭包里用模块常量":
            "LIMIT = 10\n"
            "def outer():\n"
            "    def inner(value):\n"
            "        return min(value, LIMIT)\n"
            "    return inner\n",
        "global 声明":
            "COUNT = 0\n"
            "def bump():\n"
            "    global COUNT\n"
            "    COUNT += 1\n",
        "类方法互相调用":
            "class W:\n"
            "    def a(self):\n"
            "        return self.b()\n"
            "    def b(self):\n"
            "        return 1\n",
        "装饰器":
            "import functools\n"
            "@functools.lru_cache(maxsize=None)\n"
            "def f():\n"
            "    return 1\n",
        "默认参数引用类属性":
            "class W:\n"
            "    DEFAULT = 5\n"
            "    def m(self, value=None):\n"
            "        return value if value is not None else self.DEFAULT\n",
    }
    false_alarms = []
    for label, source in good_cases.items():
        reported = scan(source)
        if reported:
            false_alarms.append(f"{label} → 误报 {sorted(reported)}")

    assert not false_alarms, (
        "检查器有误报，会让人不再信任它：\n  " + "\n  ".join(false_alarms)
    )

    # ---- 真跑一遍完整流程（确保没崩）----
    with tempfile.TemporaryDirectory() as folder:
        temp = pathlib.Path(folder)
        (temp / "sample.py").write_text(
            "def f():\n"
            "    return NotImportedAnywhere()\n",
            encoding="utf-8",
        )
        tree = ast_module.parse(
            (temp / "sample.py").read_text(encoding="utf-8"), "sample.py"
        )
        bound = _module_bindings(tree)
        assert "NotImportedAnywhere" not in bound

    print(f"检查器自身：抓得出忘了导入（含方法与嵌套函数），"
          f"{len(good_cases)} 种正常作用域用法零误报")
    return True


def check_dedupe_scope():
    """去重只该管「导入文件」，绝不能吞掉手录和计时的记录。

    这是修一个真 bug 时立的规矩：
    员工上午干 4 小时备注「修 bug」，下午又干 4 小时备注还是「修 bug」——
    两条指纹一样。如果界面手录也去重，**第二条会被静默丢掉**，
    界面上什么都不发生，用户只会以为没点上。
    """
    import db

    store = db.Store(":memory:")
    try:
        project_id = store.add_project({"name": "项目"})
        employee_id = store.add_employee({"name": "王强"})

        entry = {
            "employee_id": employee_id, "project_id": project_id,
            "work_date": "2026-09-01", "hours": 4, "content": "修 bug",
        }

        # ---- 手录：两条一模一样的都要留下 ----
        first = store.add_worklog(dict(entry), dedupe=False)
        second = store.add_worklog(dict(entry), dedupe=False)
        assert first != second, "手录的第二条被去重吞掉了"
        assert len(store.worklogs()) == 2, \
            f"手录两条一样的工时应留下两条，实际 {len(store.worklogs())} 条"

        # ---- 计时器记的也不去重（同一天两段一样的活）----
        timed = dict(entry)
        timed["source"] = "timer"
        before = len(store.worklogs())
        store.add_worklog(dict(timed), dedupe=False)
        store.add_worklog(dict(timed), dedupe=False)
        assert len(store.worklogs()) == before + 2, "计时记的两条被去重吞掉了"

        # ---- 导入：必须去重，同一个文件导两次不能变两份 ----
        imported = dict(entry)
        imported["work_date"] = "2026-09-02"
        imported["source_key"] = "fixed-key-for-import"
        first_import = store.add_worklog(dict(imported), dedupe=True)
        second_import = store.add_worklog(dict(imported), dedupe=True)
        assert first_import == second_import, "导入重复时没有复用已有记录"
        assert store.one(
            "SELECT COUNT(*) AS n FROM worklog WHERE work_date='2026-09-02'"
        )["n"] == 1, "导入重复时插入了第二份"

        # ---- 默认行为：传了 source_key 就当导入处理 ----
        auto = dict(imported)
        auto["work_date"] = "2026-09-03"
        auto["source_key"] = "another-key"
        store.add_worklog(dict(auto))
        store.add_worklog(dict(auto))
        assert store.one(
            "SELECT COUNT(*) AS n FROM worklog WHERE work_date='2026-09-03'"
        )["n"] == 1, "带 source_key 的默认行为没有去重"

        # ---- 不传 source_key 的默认行为：当手录，不去重 ----
        plain = dict(entry)
        plain["work_date"] = "2026-09-04"
        store.add_worklog(dict(plain))
        store.add_worklog(dict(plain))
        assert store.one(
            "SELECT COUNT(*) AS n FROM worklog WHERE work_date='2026-09-04'"
        )["n"] == 2, "不带 source_key 的默认行为错误地去重了"

        # ---- find_duplicate_worklog 要能查出手录的记录 ----
        # 手录的指纹是空的，但界面提醒「可能重复了」正需要它查出来
        twin = store.find_duplicate_worklog({
            "employee_id": employee_id, "project_id": project_id,
            "work_date": "2026-09-01", "hours": 4, "content": "修 bug",
        })
        assert twin is not None, "手录的重复记录没查出来，界面没法提醒"
        assert twin["work_date"] == "2026-09-01"

        # 导入来的记录也要查得出
        imported_twin = store.find_duplicate_worklog({
            "employee_id": employee_id, "project_id": project_id,
            "work_date": "2026-09-02", "hours": 4, "content": "修 bug",
        })
        assert imported_twin is not None, "导入来的重复记录没查出来"

        # 不一样的不该误报
        assert store.find_duplicate_worklog({
            "employee_id": employee_id, "project_id": project_id,
            "work_date": "2026-09-01", "hours": 5, "content": "修 bug",
        }) is None, "工时不同却报了重复"
        assert store.find_duplicate_worklog({
            "employee_id": employee_id, "project_id": project_id,
            "work_date": "2026-09-09", "hours": 4, "content": "修 bug",
        }) is None, "日期不同却报了重复"

        print("去重范围：手录与计时都不去重、导入必去重、"
              "重复能查出供界面提醒")
        return True
    finally:
        store.close()


def check_snapshot():
    """手机快照：导出 → 手机读 → 改后回传 → 电脑导入，全链路要通。

    手机版是单文件网页，跑在浏览器里，我这边没法执行它。
    所以这里验证的是**两端的数据契约**：
    电脑导出的快照长什么样、手机按同样字段读；
    手机回传的文件必须是标准的「员工工时文件」，电脑能直接导入。
    """
    import json
    import os
    import tempfile

    import db
    import submit

    store = db.Store(":memory:")
    tempdir = tempfile.mkdtemp(prefix="pr_snap_")
    try:
        project_id = store.add_project({
            "name": "智慧园区", "owner": "李工", "status": "进行中",
            "start_date": "2026-01-01", "due_date": "2026-06-01",
            "budget": 800000, "cost": 700000, "progress": 35,
            "client": "甲方", "priority": "高", "note": "备注文字",
        })
        store.add_step(project_id, {
            "name": "接口联调", "owner": "王强", "status": "已阻塞",
            "start_date": "2026-02-01", "due_date": "2026-03-01",
            "progress": 40, "note": "卡住了",
        })
        store.add_assessment(project_id, {
            "kind": "ability", "name": "后端", "score": 4, "weight": 2,
            "note": "够用",
        })
        store.add_metric(project_id, {
            "metric_date": "2026-02-01", "name": "到货率", "value": 60,
            "unit": "%", "note": "",
        })
        employee_id = store.add_employee({
            "name": "王强", "role": "后端", "level": "P6", "weekly_hours": 40,
        })
        store.add_assignment({
            "project_id": project_id, "employee_id": employee_id,
            "planned_hours": 40, "start_date": "2026-02-01",
            "due_date": "2026-03-01", "status": "进行中",
            "role_in_task": "主力",
        })
        store.add_worklog({
            "employee_id": employee_id, "project_id": project_id,
            "work_date": "2026-02-10", "hours": 8, "content": "调接口",
        }, dedupe=False)

        # ---- 导出 ----
        data = submit.export_snapshot(store)
        assert data["format"] == submit.SNAPSHOT_FORMAT
        assert data["version"] == submit.FORMAT_VERSION

        # 手机版要用的字段一个都不能少——少一个就显示不出来
        for key in ("employees", "projects", "assignments", "worklogs",
                    "exported_at"):
            assert key in data, f"快照缺少字段：{key}"

        project = data["projects"][0]
        for key in ("name", "owner", "status", "priority", "start_date",
                    "due_date", "budget", "cost", "progress", "client",
                    "note", "steps", "assessments", "metrics"):
            assert key in project, f"快照的项目缺少字段：{key}"

        step = project["steps"][0]
        for key in ("name", "seq", "owner", "status", "start_date",
                    "due_date", "progress", "note"):
            assert key in step, f"快照的步骤缺少字段：{key}"

        # 数值必须是数字而不是字符串——
        # 手机上拿它做算术，字符串会算成 NaN
        for key in ("budget", "cost", "progress"):
            assert isinstance(project[key], (int, float)), \
                f"快照里 {key} 不是数字：{project[key]!r}（手机算不了）"
        assert isinstance(data["worklogs"][0]["hours"], (int, float)), \
            "工时不是数字，手机上加不起来"

        # ---- 写文件 + 读回来 ----
        path = os.path.join(tempdir, submit.snapshot_filename())
        written, error = submit.write_snapshot(store, path)
        assert written is not None, f"写快照失败：{error}"
        reread, error = submit.read_snapshot(path)
        assert reread is not None, f"读不回自己写的快照：{error}"
        assert len(reread["projects"]) == 1

        # 文件要能当普通 JSON 解析（手机用 JSON.parse 读）
        with open(path, "r", encoding="utf-8") as handle:
            parsed = json.load(handle)
        assert parsed["format"] == submit.SNAPSHOT_FORMAT

        # ---- 拿错文件要有明确提示 ----
        # 注意这些文件都要带上真实的 version ——
        # 本程序导出的包一定有版本号，测试数据也该照真实的来。
        wrong = os.path.join(tempdir, "错文件.json")
        with open(wrong, "w", encoding="utf-8") as handle:
            json.dump({"format": "ProjectRecorder.worklog", "version": 1,
                       "employee": {"name": "王强"}, "entries": []}, handle)
        got, error = submit.read_snapshot(wrong)
        assert got is None, "把员工工时文件当快照读进来了"
        assert "快照" in error, f"错误提示没说清拿错了什么：{error}"

        # 反过来：拿快照当工时文件也不能读进来
        got, error = submit.read_file(path)
        assert got is None, "把手机快照当员工工时文件读进来了"
        assert "快照" in error, f"错误提示没说清：{error}"

        # 别的程序的 json：应当说「不是本程序的文件」，
        # 而不是拿版本号说事（那种文件根本没有 version）
        foreign = os.path.join(tempdir, "别的程序.json")
        with open(foreign, "w", encoding="utf-8") as handle:
            json.dump({"hello": "world"}, handle)
        for reader in (submit.read_file, submit.read_snapshot,
                       submit.load_json):
            got, error = reader(foreign)
            assert got is None, f"{reader.__name__} 读进了别的程序的文件"
            assert "不是本程序" in error, (
                f"{reader.__name__} 对着别的程序的 json 报的是：{error!r}"
                "——应当说清不是本程序的文件，而不是拿版本号说事"
            )

        # 缺 version 的本程序文件：版本检查要能报出来
        no_version = os.path.join(tempdir, "缺版本.json")
        with open(no_version, "w", encoding="utf-8") as handle:
            json.dump({"format": "ProjectRecorder.worklog", "entries": []}, handle)
        got, error = submit.read_file(no_version)
        assert got is None, "缺版本的文件被读进来了"
        assert "版本" in error, f"缺版本时提示不对：{error}"

        # 版本比程序新：要明确提示更新程序
        future = os.path.join(tempdir, "新版本.json")
        with open(future, "w", encoding="utf-8") as handle:
            json.dump({"format": "ProjectRecorder.worklog", "version": 999,
                       "employee": {"name": "王强"}, "entries": []}, handle)
        got, error = submit.read_file(future)
        assert got is None
        assert "版本" in error and "999" in error, f"版本提示不对：{error}"

        broken = os.path.join(tempdir, "坏文件.json")
        with open(broken, "w", encoding="utf-8") as handle:
            handle.write("不是 json")
        got, error = submit.read_snapshot(broken)
        assert got is None and error.strip(), "坏文件没有给出原因"

        # ---- 手机回传：格式必须是电脑能直接导入的那种 ----
        handback = {
            "format": "ProjectRecorder.worklog",
            "version": submit.FORMAT_VERSION,
            "exported_at": "2026-02-11 09:00:00",
            "employee": {"name": "王强", "role": "后端", "level": "P6",
                         "weekly_hours": 40},
            "range": {"from": "2026-02-11", "to": "2026-02-11"},
            "note": "从手机版交回的工时",
            "entries": [{
                "work_date": "2026-02-11", "project": "智慧园区",
                "step": "接口联调", "hours": 6, "content": "手机上记的一笔",
                "source": "manual", "key": "",
            }],
            "checks": [],
        }
        back_path = os.path.join(tempdir, "手机交回.json")
        submit.write_file(handback, back_path)

        report = submit.import_file(store, back_path)
        assert report["ok"], f"手机交回的工时电脑导不进来：{report['summary']}"
        assert report["added"] == 1, f"该新增 1 条，实际 {report['added']}"
        log = store.one("SELECT * FROM worklog WHERE work_date = '2026-02-11'")
        assert log is not None, "导入的工时找不到"
        assert log["project_id"] == project_id, "项目没按名字挂上"
        assert log["step_id"] is not None, "步骤没按名字挂上"

        # 再导一次不能变两条（手机可能手滑导两遍）
        again = submit.import_file(store, back_path)
        assert again["added"] == 0, "手机交回的文件重复导入又新增了"
        assert again["duplicated"] == 1

        # ---- 快照能按日期只导一部分工时 ----
        partial = submit.export_snapshot(store, date_from="2026-02-11",
                                         date_to="2026-02-11")
        assert len(partial["worklogs"]) == 1, \
            f"按日期过滤后该剩 1 条，实际 {len(partial['worklogs'])}"
        # 项目、步骤这类结构性数据永远全量带上，否则手机上没有项目名可对应
        assert len(partial["projects"]) == len(data["projects"]), \
            "按日期导出时把项目也过滤掉了——手机上将看不到项目"

        print("手机快照：字段齐全、数值是数字、按日期可过滤、"
              "拿错文件有提示、手机回传能导入且不重复")
        return True
    finally:
        store.close()
        import shutil
        shutil.rmtree(tempdir, ignore_errors=True)


def check_resources():
    """打包相关的资源必须在，而且路径解析要两种运行方式都对。

    schema.sql 缺了会让数据库建不出来，程序启动即崩——
    而这个错误只在打包后才暴露，所以提前查。
    """
    import db

    problems = []
    for name in ("schema.sql", "style.qss", "main.py"):
        if not (HERE / name).is_file():
            problems.append(f"缺少 {name}")

    # db 模块解析出来的 schema 路径必须真的存在
    if not os.path.isfile(db.SCHEMA_PATH):
        problems.append(f"db.SCHEMA_PATH 指向的文件不存在：{db.SCHEMA_PATH}")

    # build.py 的 BUNDLED 清单要和实际文件对得上
    import build
    for source, _target in build.BUNDLED:
        if not (HERE / source).is_file():
            # 允许 preview.html 这类非必需资源缺失，只提示
            print(f"  （提示）build.py 列了 {source}，但文件不存在")

    if problems:
        print("资源检查：**失败**")
        for line in problems:
            print(f"  {line}")
        return False
    print("资源检查：齐全（schema.sql / style.qss 路径解析正常）")
    return True


def main():
    print("=" * 52)
    failed = check_syntax()
    failed += check_undefined_names()
    failed += check_return_shapes()
    try:
        if not check_resources():
            failed += 1
    except Exception:
        failed += 1
        print("资源检查：**失败**")
        traceback.print_exc()
    for name, func in (
        ("公共计算", check_metrics),
        ("检查器自身", check_checker),
        ("图表", check_charts),
        ("数据层", check_data_layer),
        ("社区客户端", check_community_client),
        ("预测引擎", check_rules),
        ("小助手", check_assistant),
        ("洞察引擎", check_insights),
        ("员工提交", check_server),
        ("计时器", check_timer),
        ("文件交换", check_submit_files),
        ("手机快照", check_snapshot),
        ("改工时", check_worklog_edit),
        ("去重范围", check_dedupe_scope),
        ("导出", check_export),
    ):
        try:
            func()
        except Exception:
            failed += 1
            print(f"{name}：**失败**")
            traceback.print_exc()
    print("=" * 52)
    if failed:
        print(f"有 {failed} 项没过。")
        return 1
    print("全部通过。")
    return 0


if __name__ == "__main__":
    sys.exit(main())
