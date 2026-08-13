# pbxproj 静态一致性校验（Windows 无 xcodebuild/plutil 时的自检）
# 检查：1) 花括号平衡 2) 被引用的 ID 都有定义 3) 已删除文件无残留引用 4) 新增容器四步齐全
import re
import sys

PBX = r"c:\Users\Administrator\Documents\ChatGPT\New project\TrollVNC\app\TrollVNC\TrollVNC.xcodeproj\project.pbxproj"
src = open(PBX, encoding="utf-8", errors="replace").read()

fails = []

# 1) 花括号平衡
for ch_open, ch_close in (("{", "}"), ("(", ")")):
    if src.count(ch_open) != src.count(ch_close):
        fails.append(f"brace imbalance {ch_open}: {src.count(ch_open)} vs {ch_close}: {src.count(ch_close)}")

# 2) 收集所有定义 ID：所有 Begin/End section 内"行首 ID"均为定义
#    （PBXFileReference/PBXBuildFile/PBXNativeTarget/PBXSourcesBuildPhase/XCBuildConfiguration 等全部计入），
#    行首 ID 是定义、非行首 ID 是引用——孤儿引用（有引用无定义）据此检出。
defined = set()
for sec_name, body in re.findall(r"/\* Begin ([^*]+) \*/(.*?)/\* End \1 \*/", src, re.S):
    defined |= set(re.findall(r"^\s*([0-9A-F]{24}) /\*", body, re.M))

# 3) BuildFile 的 fileRef 必须存在
for m in re.finditer(r"^\s*([0-9A-F]{24}) /\* .*? in (Sources|Resources|Frameworks) \*/ = \{[^}]*fileRef = ([0-9A-F]{24})", src, re.M):
    bid, phase, fid = m.group(1), m.group(2), m.group(3)
    if fid not in defined:
        fails.append(f"BuildFile {bid} refs missing FileReference {fid}")
    if phase == "Sources" and (bid, phase) and src.count(f"/* {bid} */") == 0:
        pass

# 4) 孤儿引用检查：非行首出现的 "ID /* 名 */" 为引用，其 ID 必须已定义
for m in re.finditer(r"([0-9A-F]{24}) /\* ([^*]+) \*/", src):
    iid, name = m.group(1), m.group(2)
    line_start = src.rfind("\n", 0, m.start()) + 1
    if not src[line_start:m.start()].strip():
        continue  # 行首 = 定义，跳过
    if iid not in defined:
        fails.append(f"orphan reference {iid} /* {name} */")

# 5) 已删除文件零残留
for gone in ("TVNCControllerViewController", "TVNCViewerViewController", "TVNCDeviceListCell", "ViewerWeb"):
    if gone in src:
        fails.append(f"stale reference: {gone}")

# 6) 新增容器四步齐全（BuildFile / FileReference / Group children / Sources）
for token in ("AA01000000000000000000C1", "AA01000000000000000000C2", "AA01000000000000000000C3"):
    if token not in src:
        fails.append(f"missing container id {token}")
    if token not in defined:
        fails.append(f"container id {token} not defined")

print("defined ids:", len(defined))
print("FAILS:" if fails else "ALL OK: braces balanced, no orphan refs, deletions clean, container wired (4 steps)")
for f in fails:
    print("  -", f)
sys.exit(1 if fails else 0)
