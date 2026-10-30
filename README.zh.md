<div align="center">

# DeepSeek Harnix

[DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness)（dsh）的 Nix 打包与声明式配置。

[English](README.md) | 中文

[![CI](https://github.com/WangYiBen0/deepseek-harnix/actions/workflows/ci.yml/badge.svg)](https://github.com/WangYiBen0/deepseek-harnix/actions/workflows/ci.yml)
[![Update dsh versions](https://github.com/WangYiBen0/deepseek-harnix/actions/workflows/update-versions.yml/badge.svg)](https://github.com/WangYiBen0/deepseek-harnix/actions/workflows/update-versions.yml)
[![Built with Nix](https://img.shields.io/badge/Built_With-Nix-5277C3.svg?logo=nixos&labelColor=73C3D5)](https://nixos.org)
[![platforms](https://img.shields.io/badge/platforms-x86__64--linux_%7C_aarch64--linux_%7C_aarch64--darwin-informational)](#平台)
[![powered by dsh](https://img.shields.io/badge/powered_by-dsh-4D6BFE?style=flat-square&logo=deepseek&logoColor=white)](https://github.com/deepseek-ai/deepseek-harness)

**每一个已打包的 dsh 发行版**都会成为一个包集合，**树外插件**
可从 npm 或任意源码树构建，**profile** 则以声明式方式管理。

</div>

- **每一个已打包的 dsh 发行版**都会成为
  `legacyPackages.<system>.dshPackageSets` 下的一个包集合，并提供
  `latest` / `latestRc` / `latestStable` / … 等 channel 快捷方式；其
  `deepseek-harness` 可用 `.override { pluginList = [ … ]; }` 覆盖，
- **`unstable`** 构建上游默认分支的固定头部（`pkgs/unstable.json`），
  因此总有一个比最新发行版更新的包集合，
- **`mkDshPlugin`** 可从 npm 包或任意源码树构建树外插件（"bundle"）——
  无需手动填写元数据，
- **`pkgs/versions.json`** 是一份只追加的 hash 列表；GitHub Action 会自动
  追加新的上游 `dsh-v*` 发行版，
- **NixOS / Home Manager 模块**以声明式方式管理 dsh profile 及其插件列表，
  并可将 Web UI 作为 systemd 用户服务运行。

## 快速开始

```console
# 运行最新的已打包发行版
$ nix run .#dsh

# 某个 channel 的最新版——它们是真实存在的包，所以 `nix flake show` 能列出
$ nix build .#deepseek-harness-rc
$ nix build .#deepseek-harness-unstable      # upstream's default branch head

# 构建指定发行版。没有任何东西被预先实例化：只有在点名该版本时才会从
# 版本字符串生成包，因此 `packages` 不会随发行版列表增长。
$ nix build .#legacyPackages.x86_64-linux.dshPackageSets."0.2.1-rc.2".deepseek-harness

# 在 Nix 代码里可以跳过 attrset，直接调用生成器
$ nix eval --impure --raw --expr '((builtins.getFlake (toString ./.))
    .legacyPackages.x86_64-linux.dshPackage "0.2.1-rc.2").drvPath'

# 列出已打包的发行版与 channel。`nix flake show` 在这里帮不上忙：它只打印
# derivation，而 attribute set 套 attribute set 并不是 derivation。
$ nix eval .#legacyPackages.x86_64-linux.dshPackageSets --apply builtins.attrNames
[ "0.1.0-rc.7" "0.1.0-rc.8" … "0.2.1-rc.2" "0.2.1-rc.3"
  "latest" "latestAlpha" "latestRc" "unstable" ]
```

## 平台

| `systems` 条目 | 状态 |
| --- | --- |
| `x86_64-linux` | CI 会构建端到端插件检查、Home Manager 模块检查以及包测试 |
| `aarch64-linux` | CI 在原生 ARM runner 上构建同一组检查；不运行 NixOS VM 测试（托管的 ARM runner 没有 KVM） |
| `aarch64-darwin` | 每次 push 都在 CI 中求值（`nix flake check --all-systems`）；同样的包定义、同样的插件构建器，但既不构建也不运行任何东西——没有 macOS runner |

未列出 Intel Mac：当前 nixpkgs 已移除 `x86_64-darwin`，因此对该系统求值会在
这个 flake 的任何代码运行之前就中止。

代码树中有三处平台分支，其中只有前两处仅限 Linux：

- 运行时 wrapper 仅在 Linux 上把 `bubblewrap` 加入 `PATH`（macOS 没有
  namespace sandbox；wrapper 干脆不带它），
- `programs.dsh.services.web` 是 systemd 用户单元，因此在 Darwin 上是
  空操作，
- NixOS VM 测试与 registry tarball 检查（通过 import-from-derivation
  读取 tarball 元数据）只在其能运行的地方存在。

除此之外——包、profile、插件构建和 CLI——都与平台无关。

`dshPackageSets` 的键是精确的版本字符串加上 channel 快捷方式：
`latest`（总体最新）、`unstable`（固定的分支头部）以及 `latest<Channel>`——
`latestStable`、`latestRc`、`latestBeta`、`latestAlpha`——仅在对应 channel
有发行版时存在。channel 由 semver 的预发布标签推导。

Flake 输出：

| 输出 | 内容 |
| --- | --- |
| `packages.<system>.deepseek-harness` | 最新发行版（也是 `default`）——没有按发行版划分的包，因此列表不会随发行版数量增长 |
| `packages.<system>.deepseek-harness-<channel>` | `-stable`、`-rc`、`-beta`、`-alpha`：每个有发行版的 channel 一个别名，与其版本是同一个 derivation |
| `packages.<system>.deepseek-harness-unstable` | 上游默认分支的固定头部（`pkgs/unstable.json`） |
| `apps.<system>.*` | `dsh`——无需安装即可运行 CLI |
| `packages.<system>.dsh-plugin-registry` | 由精选插件目录构建的静态 npm registry 树 |
| `legacyPackages.<system>.dshPackageSet` | 函数 `version -> package set`（仅限 Nix 代码；按需实例化一个发行版） |
| `legacyPackages.<system>.dshPackage` | 函数 `version -> deepseek-harness` derivation（仅限 Nix 代码） |
| `legacyPackages.<system>.dshPackageSets.<version>` | 每个发行版一个包集合，以精确版本字符串为键（每个条目是一个 thunk） |
| `legacyPackages.<system>.dshPackageSets.latest`, `.latestRc`, …, `.unstable` | channel 快捷方式（每个预发布标签的最新版，以及分支头部） |
| `legacyPackages.<system>.dshPlugins` | 精选插件目录（`pkgs/dsh-plugins.nix`） |
| `lib.mkDshPluginFor.<system>` | 针对指定系统的插件构建器（纯求值可用）；`lib.mkDshPlugin` 是 impure 形式 |
| `overlays.default` | 将 `deepseek-harness`、`mkDshPlugin` 和 `dshPackageSets`（仅按版本为键，没有 `latest`/`unstable` 快捷方式）注入 pkgs |
| `nixosModules.default`, `homeModules.default` | 声明式 profile 和服务 |
| `checks.<system>.*` | 共十个 check；其中 `plugin-e2e`、`dsh-modules-vm`、`home-manager-module` 是关键（见「开发」） |

每个包集合都暴露 `deepseek-harness`（别名 `dsh`）、`withPlugins`、
`mkDshPlugin` 和 `version`。

顶层只使用 flake schema 中的名称（`packages`、
`apps`、`checks`、`lib`、`legacyPackages`、`overlays`、`nixosModules`、
`homeModules`）：像 `dshPackageSets` 这样的自定义输出会让 `nix flake
check` 打印 `warning: unknown flake output …`，并让 `nix flake show` 将其
显示为 `unknown`，因此非 derivation 数据改为放在 `legacyPackages` 下。
Home Manager 的入口是 `homeModules`，上游 Nix 在它的 flake schema
（`src/nix/flake.cc`）中把 `homeModules` 列为已知输出——
`homeManagerModules` 是错误的名称。Lix 2.9x 仍早于该条目，会警告
`unknown flake output 'homeModules'`；警告无害，输出本身可用。另外要注意，
两种实现下 `nix flake show` 都会把函数型输出（`lib`、`homeModules`、
`overlays`）显示为 `unknown`。

## 预置插件

dsh 从两个锚点加载插件（"bundle"）：先是正在运行的安装，然后是活动 profile
的 `node_modules`。`pluginList` 把插件包符号链接进安装目录，因此
**每个 profile** 都能使用它们，无需运行包管理器，也无需网络访问：

```nix
# 为指定系统构建插件。flake 输出是纯求值，不能用 builtins.currentSystem，
# 所以系统必须写明；在 NixOS / Home Manager 里直接用 overlay 提供的
# pkgs.mkDshPlugin 即可。
let
  flake = builtins.getFlake "github:WangYiBen0/deepseek-harnix";
  system = "x86_64-linux";
  mkDshPlugin = flake.lib.mkDshPluginFor.${system};
in
(flake.legacyPackages.${system}.dshPackageSets.latest.deepseek-harness).override {
  pluginList = [
    (mkDshPlugin {
      source = fetchFromGitHub {
        owner = "acme";
        repo = "dsh-plugin-acme";
        tag = "v1.2.3";
        hash = "sha256-…";
      };
      # 首次构建先留 `pnpmDepsHash = lib.fakeHash;`，
      # 报错里会打印真实的 "got:" hash，复制进来即可。
      pnpmDepsHash = "sha256-…";
    })
  ];
}
```

预置意味着**可解析**，而非已激活：激活是按 profile 的状态
（参见模块章节，或用 `dsh plugin` / Web UI 的插件管理器交互式激活）。

### `mkDshPlugin`

```nix
mkDshPlugin {
  # 二选一（只能给一个；源码树用 `source`）：
  source = fetchFromGitHub { … };       # 任意源码树 / fetcher 结果
  npmName = "@acme/dsh-plugin-acme";    # 或从 npm registry 拉取，需同时给出
  npmVersion = "1.2.3";                 #   版本号
  hash = "sha256-…";                    #   与 registry tarball 的 hash

  # 可选：
  packageDir = "packages/plugin";       # workspace 成员（monorepo）
  pname = "…";                          # 覆盖从 package.json 探测到的
  version = "…";                        #   元数据
  pnpmDepsHash = lib.fakeHash;          # 依赖 store hash（pnpm 项目）
  npmDepsHash = lib.fakeHash;           # … 或 npm / yarnDepsHash（yarn）
  npmLockfile = ./package-lock.json;    # 未自带 lockfile 的 tarball 用
  npmBuildScript = "build";             # 同时作为 pnpmBuildScript
  npmBuild = false;                     # 重新构建自带 lib/ 的 tarball
  npmRegistry = null;                   # 构建期的 registry 覆盖
  autoInstallPeers = null;              # null = 跟随 lockfile
  npmFlags = null;                      # 额外的 `npm ci` 参数
  dshVersionRange = ">=0.2.1-alpha.1 <0.3";  # 静态兼容性门禁
  nestedPnpmDeps = fetchPnpmDeps { … }; # 嵌套 workspace 的 pnpm store
  nestedPnpmDir = "vendor/dsh-std";     # … 以及指向它的位置
  pruneDevDependencies = false;         # 从输出中剔除 devDependencies
  env = { … };                          # 额外构建环境变量
  nativeBuildInputs = [ … ];
  meta = { … };
}
```

行为：

- 包名/版本/描述从源码的 `package.json` 读取
  （一次很小的 import-from-derivation 读取，由 Nix 缓存），
- lockfile 决定使用哪个包管理器（pnpm / npm / yarn），全程离线构建；
  声明了依赖却未附带 lockfile 的插件会被拒绝并给出说明，
- 输出是插件包目录（`package.json` 位于 `$out`）连同其 `node_modules`
  ——一个自包含的包，形状与 dsh 的 profile 加载器对树外 bundle 的期望一致，
- 一个 pnpm workspace 若还要构建带自己 lockfile 的**嵌套** workspace
  （`vendor/…`，一个 git submodule），需要它自己的依赖 store：
  解包 `nestedPnpmDeps`，并给 `nestedPnpmDir` 的 `pnpm-workspace.yaml`
  追加 `storeDir` + `offline`（pnpm 11 在这些设置上忽略 `.npmrc` 和
  `npm_config_*`），
- `npmBuildScript` 为两种包管理器选择脚本；从 `build` 运行验证 harness
  的插件（dsh-tui）可将其指向 `compile`，
- peer（cordis 及其同类）**不会**自动安装（`autoInstallPeers =
  false`）：dsh 的运行时解析器会把安装中唯一的共享实例提供给每个 profile
  插件，因此插件绝不能打包第二份 cordis。

可通过 `lib.mkDshPluginFor.<system>` 访问，也可通过 `overlays.default`
作为 `pkgs.mkDshPlugin` 访问，或按包集合访问：
`legacyPackages.<system>.dshPackageSets.latest.mkDshPlugin`。不带系统前缀的
`lib.mkDshPlugin` 只在 impure 求值下可用（它读取 `builtins.currentSystem`）；
在纯 flake 求值中它会直接抛错，而不是猜一个系统。

## 声明式 profile（NixOS / Home Manager）

这些模块把 dsh profile 具体化为 store 构建的模板，并同步到
`<DSH_HOME>/profiles/<name>`，成为真实、可写的目录（包含 bundle 列表和插件
依赖的 manifest、用户 patch 层，以及 dsh 的 pnpm 设置）。dsh 每次启动都会
重写 profile 的根 include 文件，因此只读符号链接行不通。插件包从 store
符号链接进 profile 的 `node_modules`——dsh 把这类树外链接视为 linked root
——所以启动时**完全不涉及包管理器，也不涉及网络**。

```nix
# Home Manager——两行就是一个可用的 web profile
{ inputs, ... }:
{
  imports = [ inputs.deepseek-harnix.homeModules.default ];

  programs.dsh = {
    enable = true;
    profiles.web.template = "web";   # 随附的 web 模板，bundle 列表已内置
    services.web.enable = true;      # 生成 `dsh-web` systemd 用户单元
  };
}
```

这就是全部配置：`package` 默认为本 flake 自己的构建（带 shell 补全的那个），
`dshHome` 默认为 `~/.dsh`。

需要插件和 patch 层时，展开写是这样：

```nix
{ inputs, pkgs, ... }:
{
  imports = [ inputs.deepseek-harnix.homeModules.default ];

  programs.dsh = {
    enable = true;

    profiles.work = {
      # 也可以直接指定随附模板（`web`、`acp`、`headless`、`sdk`、
      # `sdk-minimal`）并完全略去 `bundles`——模板定义了整个列表，
      # 因此两者同时写会被拒绝。
      bundles = [ "@deepseek-ai/dsh-web-app" ];

      # 要安装并启用的插件，按 bundle 顺序。
      plugins = [
        (pkgs.mkDshPlugin { source = ./my-plugin; })
      ];
      # 只安装、不启用的插件（等价于插件列表里被禁用的一行）。
      disabledPlugins = [ ];

      # `cordis.patch.yml` 有两种归属方式，因为 dsh 会在运行时改写它：
      #
      #   `patches`     —— 配置。每次激活和每次重置都重写，命令式改动
      #                    无法保留。
      #   `seedPatches` —— 初始内容。仅在文件不存在时写入；之后的 reset
      #                    也会保留这份活文件。web UI 的模型选择器管理该
      #                    文件时用这个。
      seedPatches = [
        { id = "hmr"; disabled = true; }
      ];
    };

    services.web = {
      enable = true;
      profile = "work";
      host = "127.0.0.1";   # 必须是单个具体本地地址，通配地址会被拒绝
      port = 3080;
    };
  };
}
```

NixOS 用法相同（`nixosModules.default`），外加一个 `programs.dsh.users`
列表，用于指定哪些用户的 harness home 接收这些 profile（由系统激活脚本
同步，并 chown 给该用户）。

说明：

- `profiles.<name>.template` 原样采用某个随附模板的 bundle 列表
  （`web`、`acp`、`headless`、`sdk`、`sdk-minimal`）；不指定时，profile 以
  `@deepseek-ai/dsh-base` 开头（设置
  `profiles.<name>.includeBase = false` 可完全控制该列表），后接 `bundles`。
  随附列表供参考：web = `@deepseek-ai/dsh-web-app`, acp =
  `@deepseek-ai/dsh-acp-app`, headless = `@deepseek-ai/dsh-headless`, sdk =
  `@deepseek-ai/dsh-sdk-app`，
- `seedPatches` 与 `patches` 的区别：dsh 的 web UI、模型选择器和
  `dsh plugin` 会在运行时改写 `cordis.patch.yml`，因此 patch 层属于活状态
  的 profile 应使用 `seedPatches`（声明一次，之后归 dsh 所有），而非
  `patches`（声明本身，每次 reset 时重新应用）。激活与 `dsh-config-reset`
  都遵守这一点：seed 出的文件只会被创建，存在期间绝不会被覆盖。

### 激活只负责创建；`dsh-config-reset` 负责重新同步

`$DSH_HOME/profiles/<name>` 里有两类状态：**声明**（bundle 列表、插件、
patch 层，归 Nix 所有）与**运行时状态**（`cordis.yml`、会话、市场数据，
归 dsh 所有并在运行中改写）。因此“激活”和“重置”是两种不同的操作：

| | profile 不存在 | profile 已存在 |
|---|---|---|
| `nixos-rebuild switch` / `home-manager switch` | 按 store 模板创建 | **完全不动**；声明变了只打印一条提示 |
| `dsh-config-reset [名字…]` | 创建 | 按 store 模板覆盖声明；`cordis.yml` 等运行时状态保留，`seedPatches` 文件也保持 dsh 写入的内容 |

所以重新构建绝不会丢弃正在使用的 profile；要把改过的插件集合或 patch 层
推到已有 profile 上，需要显式执行：

```bash
dsh-config-reset            # 所有声明式 profile
dsh-config-reset web        # 只重置这一个
```

并非由该模块创建的目录（没有 `.dsh-managed` 标记）不会被激活触碰，只有在
reset 里点名时才会被接管。NixOS 上配置了多个 `programs.dsh.users` 时，
每个用户会得到各自的 `dsh-config-reset-<user>`，而不是一个会去猜的命令。

## 插件目录与 registry 订阅

`pkgs/dsh-plugins.nix` 是精选插件目录；flake 将其暴露为
`dshPlugins`，并构建为 `dsh-plugin-registry`——一个**静态 npm
registry 树**，dsh 的插件管理器可从中安装（按照 `--registry` 的处理方式，
dsh 的 registry 就是 npm registry）：

```console
$ nix build .#dsh-plugin-registry
$ cd result && python3 -m http.server 4873
# 然后在 dsh 的插件管理器里把 http://127.0.0.1:4873 设为 registry，
# 或者：pnpm --registry http://127.0.0.1:4873 add <plugin>
```

每个包都会获得一份 npm 元数据文档（`index.json`，包含
`dist.tarball`/`shasum`/`integrity`）和一个 tarball；`catalog.json`
汇总该列表。`registryBaseUrl` 可覆盖：
`dsh-plugin-registry.override { registryBaseUrl = "https://plugins.example.com"; }`。
编辑 `pkgs/dsh-plugins.nix` 即可让目录指向你自己的插件
（条目都是普通的 `mkDshPlugin` 调用）。

### 静态版本范围

目录条目（以及任何 `mkDshPlugin` 调用）都可声明 `dshVersionRange`
——一种 node-semver 范围，由 dsh 自己的 `engines.dsh` 准入所理解。只要
插件遇到 harness 版本，flake 就会**在求值时**强制执行它：

- `dshPackageSets.<v>.withPlugins [ … ]` 在某个插件的范围不接受该集合的
  版本时求值失败，
- `.deepseek-harness.override { pluginList = …; }` 同样会失败——包本身会
  检查它的 `pluginList`，所以绕过 `withPlugins` 并不能绕过门禁，
- NixOS 模块会断言、profile derivation 会失败：当某个 profile 插件不接受
  `programs.dsh.package` 时。（Home Manager 没有 `assertions` 选项，因此
  那把门禁由 profile derivation 承担。）

支持的语法：以空白/逗号分隔的 `>= > <= < =` 比较符，外加
`^` 和 `~`。示例：`dshVersionRange = ">=0.2.1-alpha.1 <0.3";`。

## Shell 补全

dsh 本身不带补全支持（commander 也没有），因此该包会把镜像 0.2.x CLI 接口的
静态脚本安装到标准路径——`share/bash-completion/completions/dsh`,
`share/zsh/site-functions/_dsh`, `share/fish/vendor_completions.d/dsh.fish`。
它们补全启动器参数、`plugin` 子命令以及 profile 名称
（运行时从 `$DSH_HOME/profiles` 读取，并与随附的模板名称合并）。把该包放入
`environment.systemPackages` / `home.packages` 后，bash-completion、zsh 和
fish 会自动识别它们。

## Web UI 作为 systemd 用户服务

`programs.dsh.services.web.enable` 会安装一个 `dsh-web` systemd **用户**
服务，运行 `dsh --profile <profile> --no-open`（默认 profile 为 `web`）：

```nix
# NixOS——该单元通过 ConditionUser 限定到所配置的用户。
programs.dsh = {
  enable = true;
  users = [ "alice" ];
  services.web.enable = true;
  services.web.profile = "work";       # a managed or shipped profile
  services.web.extraArgs = [ "--verbose" ];
};

# 无需登录即可在开机时启动：
users.users.alice.linger = true;
```

```nix
# Home Manager——该单元属于执行激活的用户。
programs.dsh.services.web.enable = true;
```

用 `systemctl --user {start,stop,status} dsh-web` 管理；日志通过
`journalctl --user -u dsh-web` 查看。

## 发行版跟踪（hash 列表）

`pkgs/versions.json` 为每个已打包的发行版保存一条记录：

```json
{ "version": "0.2.1-rc.2", "rev": "dsh-v0.2.1-rc.2",
  "srcHash": "sha256-…", "pnpmDepsHash": "sha256-…" }
```

[`.github/workflows/update-versions.yml`](.github/workflows/update-versions.yml)
每天运行：它会列出上游 `dsh-v*` 标签，并对列表中缺失的每个版本，用
[`scripts/prefetch-dsh-version.sh`](scripts/prefetch-dsh-version.sh) 计算源码
和 pnpm 依赖的 hash（标准的两次遍历 fake-hash 技巧，针对该 flake 锁定的
nixpkgs），然后开一个 pull request 追加这些条目，并开启自动合并，让它在 CI
通过后自行合入（`main` 要求 pull request 及其检查，因此不再有直接推送的路径）。默认的
`packages.*.deepseek-harness` 始终是**最后**一条。

该列表覆盖**每一个**历史上的上游标签，因此旧发行版仍然可构建、可寻址——
例如
`nix build .#legacyPackages.x86_64-linux.dshPackageSets."0.1.5-rc.3".deepseek-harness`。请注意，
打包逻辑（`pkgs/deepseek-harness.nix`）是针对当前 dsh 维护的：
标签越旧，其构建越可能需要打包方面的工作，即使它的 hash 能正常解析。

手动添加发行版：

```console
$ ./scripts/prefetch-dsh-version.sh 0.2.1-rc.2 > new.jsonl
$ python3 scripts/merge-versions.py pkgs/versions.json new.jsonl
```

同一个 workflow 也会维护 `pkgs/unstable.json`。该文件是单个*移动*的固定点，
而不是列表：

```json
{ "branch": "master", "version": "0.2.1-rc.3",
  "commit": "22ddee3…", "srcHash": "sha256-…", "pnpmDepsHash": "sha256-…" }
```

它记录上游默认分支的头部（是 `master`，不是 `main`），
`dshPackageSets.unstable` 构建的正是该 commit——所以它比最新发行版更新，
又不是漂移不定的目标。手动刷新：

```console
$ ./scripts/prefetch-dsh-version.sh --unstable > unstable.json
$ python3 scripts/merge-unstable.py pkgs/unstable.json unstable.json
```

它的 `version` 保持上游自己的字符串（分支头部通常仍带着上个发行版的
版本号），因此 `dsh --version` 和打包的版本测试依然如实；derivation 名称
会加上 `-unstable-<shortrev>` 后缀，以便区分两次构建。

## 开发

Input 被固定到 `github:owner/repo` ref 加上记录在 flake.lock 中的
`narHash`/`rev`——绝不固定到会变的 `archive/*.tar.gz` URL，其 hash 会在上游
变化并破坏每一次求值。用 `nix flake update` 升级。

这是一个由 git 跟踪的 flake，因此它的输入是 Git **跟踪**的文件。对已跟踪
文件的未提交改动**会被**纳入——进入一份 `-dirty` 副本，Nix 会给出提示
（`warning: Git tree … is dirty`）；而**未跟踪**的文件根本不会被复制进去。
这种不对称在两个方向上都值得注意：脏工作树会静默改变你实际构建的东西，
而从没 `git add` 过的新文件对 Nix 等于不存在。构建前先 `git add`，发布用
一次干净的 commit。

```console
$ nix build .#checks.x86_64-linux.plugin-e2e   # 端到端：dsh + Nix 构建的
                                               # 插件 + 声明式 profile
$ nix flake check --all-systems                # 本机执行全部 check，
                                               # 其余系统只求值
```

值得了解的 check：

| Check | 证明什么 |
| --- | --- |
| `plugin-e2e` | 一个由 Nix 构建、经 `pluginList` 预置的插件，通过声明式 profile 挂载，并在真实 `dsh` 中让 patch 层生效 |
| `dsh-modules-vm` | 真实 NixOS VM：`$HOME` 展开、seed 的 patch 层在重建后保留、`dsh-config-reset` 语义，以及针对假模型端点的一次真实 agent 回合 |
| `home-manager-module` | 生成的激活脚本与 systemd 单元 |
| `mkDshPlugin-npm`、`mkDshPlugin-pnpm-workspace`、`mkDshPlugin-npm-registry` | 三条打包路径（npm lockfile、pnpm workspace 成员、registry tarball） |
| `range-eval` | `dshVersionRange` 的算术，以及不兼容插件会被拒绝 |
| `plugin-registry`、`unstable-pin`、`versions-json` | registry 树、移动的 `unstable` 固定点、发行版列表 |

`test/minimal-plugin/` 是端到端检查使用的仅含 patch 的 bundle 夹具：
它通过 `mkDshPlugin` 构建，用 `pluginList` 预置进 harness，通过声明式
具体化的 profile 挂载，而该检查会验证其 patch 层在运行中的 dsh 里生效。

## 插件固定与依赖锁定

这里不提交任何插件专属数据——没有按插件划分的版本表，也没有按插件划分的
lockfile——因此可构建性完全不取决于本仓库恰好包含什么。插件完全在调用处
固定：

| 对象 | 固定方式 |
| --- | --- |
| 产物 | registry tarball（`npmName` + `npmVersion`）或源码树（`source`）的 `hash` |
| 依赖树 | **你**自己的 lockfile：`npmLockfile = ./package-lock.json`，或 `pnpm-lock.yaml` 覆盖该插件的 `source` 树加上 `pnpmDepsHash` |
| ABI | `dshVersionRange`，在求值时对照 harness 版本检查 |

`package.json` 中的范围仍具有它们一贯的含义，但无法在构建*内部*解析：
Nix 构建没有网络，因此 npm/pnpm 将不得不针对一个不可达的 registry 去解析
`^1.2.3`，而且结果无论如何都得计算 hash。因此该范围只在**你**重新生成
lock 时起作用，而沙箱消费的是 lock——不是范围。自带 lockfile 或完全没有
运行时依赖的插件不需要任何额外处理。

要对已发布插件做本地兼容性运行，用例是位于被 git 忽略的 `.prefetch/` 下的
临时文件：

```console
$ mkdir -p .prefetch/cases .prefetch/locks
$ cat > .prefetch/cases/example.sh <<'EOF'
NAME=dsh-context
VERSION=0.73.3
URL=https://registry.npmjs.org/dsh-context/-/dsh-context-0.73.3.tgz
EOF
$ ./test/plugins/driver.sh .prefetch/cases/example.sh
NAME                           PASS
```

构建器的已知限制（与任何夹具无关）：

- 从**源码**构建的插件会针对其 peer（`@deepseek-ai/*`、
  cordis）编译；`mkDshPlugin` 不会把 dsh 安装注入
  `node_modules`，因此只要存在已发布的 tarball 就优先使用它，
- `build` 脚本运行的 harness 需要活的 dsh（`verify:build`）的插件，
  必须把 `npmBuildScript` 指向一个纯编译脚本。

## 仓库布局

结构类似 nixvim：精简的 `flake.nix`（flake-parts），输出接线在
`flake-modules/`，内部辅助函数在 `lib/`，包构建器在 `pkgs/`，
NixOS/HM 模块在 `modules/`。

| 路径 | 用途 |
| --- | --- |
| `flake.nix` | input + `flake-parts.lib.mkFlake`，别无其他 |
| `flake-modules/` | 输出接线：`packages.nix`（packages、apps、包集合）、`overlays.nix`、`checks.nix`、`modules.nix`（NixOS/HM 模块、`lib.mkDshPlugin`）、`lib.nix`（把 `lib/` 暴露为模块参数） |
| `lib/default.nix` | 内部辅助函数：发行版列表、版本名清理、`mkDshPackageSet` |
| `pkgs/deepseek-harness.nix` | deepseek-harness 包（版本 + hash 参数化） |
| `pkgs/mkDshPlugin.nix` | npm/GitHub → dsh 插件包构建器 |
| `test/plugins/driver.sh` | 真实插件兼容性运行的通用驱动器（用例位于 `.prefetch/`，从不提交） |
| `test/vm-modules.nix` | `checks.<system>.dsh-modules-vm` 背后的 NixOS VM 测试 |
| `test/minimal-plugin/`、`test/npm-plugin/`、`test/workspace-plugin/` | 三条 `mkDshPlugin` 打包路径的夹具 |
| `pkgs/dsh-plugin-registry.nix`、`pkgs/dsh-registry-writer.js` | 精选目录的静态 npm registry 树 |
| `pkgs/completions/` | bash/zsh/fish 脚本，以及驱动各 shell 的检查 |
| `pkgs/versions.json` | 发行版 hash 列表（只追加，由 action 维护） |
| `pkgs/unstable.json` | `dshPackageSets.unstable` 的移动固定点（由 action 维护） |
| `modules/options.nix` | 共享的 `programs.dsh` 选项 |
| `modules/nixos.nix` | NixOS 模块（激活同步、用户服务） |
| `modules/home-manager.nix` | Home Manager 模块（激活同步、用户服务） |
| `modules/dsh-profile.nix` | profile 目录模板 derivation 构建器 |
| `modules/dsh-profile-writer.js` | 写入 profile 的 `package.json`、`cordis.patch.yml` 和 `pnpm-workspace.yaml` |
| `modules/profile-range-assertions.nix` | NixOS 模块的 `dshVersionRange` 断言 |
| `modules/profile-sync.nix` | store 模板 → 可写 profile 目录同步 |
| `scripts/prefetch-dsh-version.sh` | 单个发行版的 hash 计算（`--unstable` 取分支头部） |
| `scripts/merge-versions.py` | versions.json 合并辅助脚本 |
| `scripts/merge-unstable.py` | 原地刷新 `unstable` 固定点 |
