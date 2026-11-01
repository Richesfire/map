# IAS 项目交接（当前状态）

> 下个会话先读本文件。这里只记当前有效状态、关键约束和下一步，不记迭代过程。

## 1. 工程 / 仓库 / 源文件

- **工作工程**：`D:\NSS-huangrongji\Godot\IASv1.0`（Godot 4.7，自带 git，无远程）
- **备份/发布仓库**：`D:\NSS-huangrongji\DeepSeek`
  - `origin` = `https://github.com/Hld298053408/IAS.git`
  - `godot/IASv1.0/`（工程快照，排除 `.godot`/`.git`）、`blender/*.blend`
  - 快照方式：同步 → 提交 → 推送
- **Blender 源文件**（`D:\NSS-huangrongji\Blender\铁与鳞之书项目\`）：
  - `IAS人物模型.blend`：骨架 `ren`、24fps；含用户制作的 `mount_left/mount_right` + 双手剑/骑乘左右劈 `s_*`。**Blender 侧由用户维护，不要自动改。**
  - `IAS马匹.blend`：马；含 `turn_in_place_left/right`（目前是 `walk` 的占位副本）。
  - `IAS_单手剑盾.blend`：从主文件复制；只保留原 `s_*` 并改名 `jd_*`（31 个），通用动作已删；后续在这里改单手剑+盾动作。
- **当前 glb**：`character.glb` 已重导，含 `mount_left/mount_right`；`horse.glb` 含 `turn_in_place_*`。
- **备份**：`IAS人物模型.blend.bak_before_mount_mirror`、`.bak_before_ride_attacks`、`IAS马匹.blend.bak_before_turn_in_place`、`IAS_单手剑盾.blend.bak_before_jd_rename`、`character.glb.bak_before_mount_export`。

## 2. 环境 / 校验

- Godot：`D:\steam\steamapps\common\Godot Engine\godot.windows.opt.tools.64.exe`
- Blender：`D:\steam\steamapps\common\Blender\blender.exe`（5.2，24fps）
- 改完必跑（要求 `EXIT=0`，无 `ERROR|Parse`）：
  ```powershell
  & "D:\steam\steamapps\common\Godot Engine\godot.windows.opt.tools.64.exe" --headless --path "D:\NSS-huangrongji\Godot\IASv1.0" --quit-after 30
  ```
- 强制重导：删 `.godot/imported/<file>-*` 再 `--headless --import`。

## 3. 关键约束 / 坑

- 不要用 PowerShell `Get-Content -Raw` + `Set-Content` 改 `.gd/.tscn`（ANSI 会毁中文注释）；用 edit/write。
- 提交信息用 `-F <UTF-8文件>`；控制台 `git log` 乱码属正常。
- Blender 5.2：Action 用新 layers API（`action.layers→strips→channelbags→cb.fcurves`），没有 `action.fcurves`；建槽 `act.slots.new(id_type='OBJECT', name='Armature')`。
- `Skeleton3D.set_bone_global_pose_override()` 是骨架空间；`amount=0` 清除覆盖；`get_bone_global_pose` 包含覆盖 → 先清再读。
- `BoneAttachment3D` 必须 `use_external_skeleton=true` + `external_skeleton=NodePath(...)`。
- **CollisionShape3D 不要缩放**：非等比缩放会报“缩放不一致”警告；改 shape 资源大小（`BoxShape3D.size` / `CapsuleShape3D.height/radius` 等），节点 scale 保持 1。
- `AnimationNodeBlendTree.connect_node(in,idx,out)` 只 3 参；重连 `"output"` 会报错。
- 骨架改名：人物 `Armature→ren`、马 `metarig→ma`。
- 同步备份：`robocopy "D:\NSS-huangrongji\Godot\IASv1.0" "D:\NSS-huangrongji\DeepSeek\godot\IASv1.0" /E /XD ".godot" ".git" /XF "*.tmp" "*.bak*"`；再把**三个** `.blend` 拷到 `DeepSeek\blender\`。

## 4. 当前功能

### 骑乘

- **上/下马**：`F`。`_mount()` 按玩家在马左/右侧选 `mount_left/right`；玩家进入马的 `MountArea`（`horse.tscn` 里的 BoxShape3D 矩形，调 shape 的 `size`）即可上马；可上马时屏幕中间显示 `F · 上马`（`main.tscn` → `UI/MountPrompt`）。一匹马一个鞍座：左右上马、骑乘、下马都贴同一个 `Seat`，没有右侧鞍座。左右都用导出的 `mount_left/right` 做双侧上马；右侧骑乘使用运行时镜像 Hips 的 `ride_*_right`（`_make_right_ride`）匹配 `mount_right` 结束的 `+0.48961`，避免移动时 Hips 跳到 `-0.48961` 向右偏；上马状态→骑乘步态有 0.3s 交叉淡化，马静止时保持上马末帧。骑乘/上马机位左右共用 `RideCam`/`RideCamHold`。`_dismount()` **按摄像机位置选下马侧**（+X 右 / -X 左）；倒放该侧 `*_rev`（运行时 `_make_reversed` 生成）并下到该侧（鞍座不变）；下马期间 `steer_locked=true`。下马结束会清 `last_anim_state`，并给 `*_rev`→地面移动状态加转场，按住移动键也能直接接跑步动画。左右侧均已实测。
- **跟随/步态**：`_update_riding()` 每帧贴 `rider_anchor()` 的**完整 Seat 变换**（位置 + 旋转），人物真正跟随鞍座骨骼；下马时清零根节点俯仰/侧倾。按速度 `ride_walk/trot/canter/gallop`，状态由 `_ensure_mount_states()` 运行时添加；右侧用镜像 Hips 的 `ride_*_right`。原地转向播 `turn_in_place_left/right`（速度<0.15 且按 A/D）。
- **扭转/弹簧**：`_apply_ride_twist()` 非攻击 A/D 扭躯干（Spine 0.15 / Chest 0.2）；`_setup_spring_bones()` 5 条链，骑乘时开。
- **骑乘攻击**：允许；始终保留上半身遮罩（下半身骑马）。左右劈用专用动画 `s_attack_left/right_ride_*`（`_set_ride_attack_anims()` 运行时换 6 个状态），上劈/下刺仍用地面动画。
- **侧锁定**：只在**挥刀期间**（`is_attacking`）锁 `_ride_aim_side`；`_lock_ride_aim_side()` 在挥刀开始调用（左劈=左、右劈=右，上/下取当前镜头侧）；举刀/收刀可换侧。
- **水平限幅**：`_clamp_ride_aim()`，左右劈/上劈/下刺独立，格挡用左右劈；越过中线才换侧，换侧用 `ride_aim_turn_speed` 限速、必经正前；抬高到 `ride_aim_front_free_pitch_deg` 时 min=0，低于后按 `ride_aim_front_free_blend_deg` 渐变。
- **观察镜头**：步行 `~` → `CamHold`；骑乘 `~` → `RideCamHold`；松开回 `CamDefault`/`RideCam`。

### 步战

- **腰部**：`_apply_aim_bend()` 非骑乘用 Spine 0.5 / Chest 1.0 分配（俯仰只在 Spine），避免进出攻击时胸腔突变。
- **左右挥击下身**：`_update_lateral_attack_phase()`；只有右走右劈/左走左劈触发：挥刀第 14 帧（22 帧动画）→ 下身转到该侧相反方向 + 后退步；收刀第 5 帧（8 帧动画）恢复；反向移动无反应。
- **上劈/俯仰**：`cancel_pitch` 只在 `is_blocking` 时成立。
- **`~`**：按住锁身体俯仰 + 观察机位；站定（未移动/未战斗）上身不朝镜头。

### 敌人

- `enemy.tscn` 的 `Model` 已换成 `character_model.tscn`（人形），`enemy.gd` 在 `_ready` 播 `idle_empty`。
- 碰撞仍是**不可见胶囊**（`CapsuleShape3D`；改 shape 的 radius/height，不要缩放节点）。
- 敌人自己的 `AnimationPlayer/AnimationTree` 仍为空，AI 攻击/格挡动画未接。

## 5. 当前有效参数

> player.gd 默认值可能被 `main.tscn` 覆盖，以下是**实际生效值**。

- 移动：`walk_speed=3` / `run_speed=6` / `jump_velocity=4.29` / `jump_interval=1.5` / `body_rotation_speed=3`；`max_health=100` / `attack_cooldown=0.1`（伤害在 `weapon.gd` 的 `damage=25`）。
- 骑乘：`ride_combat_blend=12`、`spring_stiffness=200` / `spring_drag=2` / `spring_gravity=0`。
- 骑乘瞄准：左右劈 `min=70/max=100`（左右同）；上劈默认 `15/90`；下刺右侧 `min=0/max=60`、左侧 `min=15/max=130`；`ride_aim_turn_speed=6`；`ride_aim_front_free_pitch_deg=-10`；`ride_aim_front_free_blend_deg=8`。
- 相机：`CAM_PITCH_MIN=-1.6` / `MAX=0.8`；marker 本地坐标：`CamDefault=(0,0.354,1.794)`、`CamHold=(0,-0.511,1.518)`、`RideCam=(0.505,1.0,2.63)`、`RideCamHold=(0.505,0.2,2.2)`；pivot = base + `(0,1.6,0)`。
- 马：`walk/trot/canter/gallop=1.8/3.6/6/9`、`back=1.5`、`accel=5`、`brake=8`、`turn=2.2`、`turn_fast=1.1`、`jump=5.5`、`gravity=12`、`gait_fade=0.25`、`ride_bone_name="spine.005"`、`turn_out_time=0.35`。
- 输入：`jump`=空格、`interact`=F、`~`=KEY_QUOTELEFT；CapsLock 切换走/跑。

## 6. 关键文件 / 函数

- `scripts/player.gd`：`_mount`/`_dismount`、`_find_mount_target`、`_update_mount_prompt`、`_mount_anim_for_side`、`_update_riding`、`_apply_ride_twist`、`_set_ride_attack_anims`、`_setup_ride_attack_anims`、`_ensure_mount_states`/`_make_reversed`、`_lock_ride_aim_side`、`_clamp_ride_aim`、`_apply_aim_bend`、`_update_head_rotation`、`_update_lateral_attack_phase`、`_cam_base_marker_pos`、`_cam_hold_marker_pos`、`_update_camera`、`_update_camera_follow`、`_process`、`_physics_process`。
- `scripts/horse.gd`：速度步态、A/D 转向、空格跳、`rider_anchor()`、`_strip_turn_tracks`、原地转步态。
- `scenes/main.tscn`：`Horse`、`CameraPivot`（`CamDefault/CamHold/RideCam/RideCamHold`）、`UI/MountPrompt`、Player 引用。
- `scenes/player.tscn`：`body_blend(Blend2)` / `move_state` / `attack_state`；上半身遮罩在 `body_blend` 过滤器。
- `scenes/horse.tscn`：`Model`（glb 转 180°）、`TurnPlayer`、`RideBone(BoneAttachment3D)+Seat`（唯一鞍座）、`MountArea`（Area3D + BoxShape3D，矩形上马范围）。
- `assets/models/character.glb`（含 `mount_left/right`、`s_attack_left/right_ride_*` 等）、`horse.glb`。
- `scripts/weapon.gd`（Area3D 伤害）、`scripts/enemy.gd`（AI 绕圈，勿删）。

## 7. 待办（下一步）

- **单手剑+盾**：在 `IAS_单手剑盾.blend` 里改 `jd_*` 动作 → 导出单独 glb → Godot 侧加载/合并动画库并做武器切换（剑/盾用 `BoneAttachment3D`，基础移动共用主库）。
- **上马右侧**：用户已导出 `mount_left/right` 并接入；一匹马一个鞍座，左右都用同一个 `Seat`。右侧骑乘切到 `ride_*_right`（镜像 Hips X），使上马末帧与移动步态的 Hips 一致；左右都正常播四个 `ride_*`。骑乘/上马机位左右共用 `RideCam`/`RideCamHold`。下马按摄像机侧（+X 右 / -X 左），鞍座不变。人物根节点完整跟随 Seat 骨骼；下马时清零俯仰/侧倾。Blender 侧由用户维护，不再自动修改。
- **骑乘上劈/下刺**：仍用地面动画；需要时按左右劈的方式补专用动画。
- **马匹原地转向**：`turn_in_place_left/right` 目前是 `walk` 副本，需改成真正的原地踏步。
- **`~` 骑乘未攻击**时对身体俯仰不生效（骑乘只在攻击/格挡跑 `_apply_aim_bend`），待确认是否补。
- **角色基础属性**：建议抽成 `CharacterStats` Resource（玩家/敌人共用一份 base；游戏内提升用运行时副本/修饰器）；相机、骑乘、瞄准、UI 等玩家专属参数留在 `player.tscn`/`PlayerConfig`，不要放在主场景实例上。
- **敌人动画**：`enemy.tscn` 已换人形并播 `idle_empty`；AI 攻击/格挡还没接 `Model/AnimationPlayer` 或 AnimationTree。
- **场景组织（可选）**：`main.tscn` 目前同时放了环境/相机/HUD/实例。可拆 `camera_rig.tscn`（CameraPivot+markers）、`hud.tscn`（CanvasLayer），Player 用导出引用或 group 连接；马/玩家/敌人/武器已各自成场景。
- 备份仓库是快照制，不含工作工程完整 git 历史。

## 8. 提交 / 推送

```powershell
$r="D:\NSS-huangrongji\DeepSeek"
git -C $r add -A
git -C $r -c user.name="IAS" -c user.email="ias@local" commit -F "<UTF-8信息文件>"
$env:GIT_TERMINAL_PROMPT=0; git -C $r push origin main
```
（推送前先跑一次上面的 headless 校验。）
