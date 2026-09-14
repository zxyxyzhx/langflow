### 使用 git 拉取最新代码

你的仓库当前只有一个远程 origin，指向你自己的 fork（zxyxyzhx/langflow）。要能拉取官方仓库的最新代码，标准做法是额外添加一个 upstream 远程指向 langflow-ai/langflow，这样你的 fork（origin）和官方仓库（upstream）互不影响。

```bash
# 添加官方仓库为 upstream 远程
git remote add upstream https://github.com/langflow-ai/langflow.git

# 确认配置成功
git remote -v

origin    https://github.com/zxyxyzhx/langflow.git   (你的 fork)
upstream  https://github.com/langflow-ai/langflow.git    (官方，只读拉取用)

# 拉取 upstream 的所有更新（不会自动合并）
git fetch upstream

# 切到你的主分支
git checkout main

# 把官方 main 合并到你当前分支
git merge upstream/main

# 之后每次想同步官方代码，只需重复
git fetch upstream
git merge upstream/main   # 或 git rebase upstream/main
```



### 参考文档

中文文档：https://docs.langflow.cn/
