#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""把版本号一次性写到所有「必须一致」的位置（1.0.4 起）。

背景：版本号此前散落在多处，改一处漏一处就会看到「包是 1.0.4、设置页底部/详情页
还写着旧号」。1.0.4 起：

  · 设置页底部的版本号改为运行期读 Info.plist（见 prefs/ERUIHelpers.m 的
    ERVersionFooterText），所以只要 Info.plist 对了，页面就一定对；
  · 剩下的机械同步点（control / Info.plist / Sileo 详情页）由本脚本负责；
  · 1.0.6-2 起还包括各处 `ver=` 诊断串：Tweak.xm，以及自带二进制的
    modules/weather/*.m（ControlCenter bundle 单独编译，主插件改了它不会跟着改）。

用法（在仓库根目录执行）:

    python scripts/er_set_version.py 1.0.5
    python scripts/er_set_version.py 1.0.6-1      # 子版本（修复迭代）
    python scripts/er_set_version.py 1.0.6-2

也可显式指定工程目录:

    python scripts/er_set_version.py 1.0.5 --project /path/to/EchoReborn

它只改「版本号」这一件事，不动任何说明文字或 changelog。CFBundleVersion 由
major*1000000 + minor*10000 + patch*100 + revision 计算，天然单调递增且可比
（1.0.6 → 1000600，1.0.6-1 → 1000601，1.0.7 → 1000700）。
"""
from __future__ import annotations

import argparse
import json
import os
import re
import sys


def find_project_root(explicit):
    """定位工程根：显式参数 > 脚本所在目录的上一级 > 再上一级的 EchoReborn。"""
    if explicit:
        return os.path.abspath(explicit)
    here = os.path.dirname(os.path.abspath(__file__))
    candidates = [
        os.path.dirname(here),                              # <repo>/scripts/ -> <repo>
        os.path.join(os.path.dirname(here), 'EchoReborn'),   # _tools/ -> ../EchoReborn
        here,
    ]
    for cand in candidates:
        if os.path.isfile(os.path.join(cand, 'control')) and \
           os.path.isfile(os.path.join(cand, 'prefs', 'Resources', 'Info.plist')):
            return cand
    raise SystemExit('cannot locate the EchoReborn project root; pass --project DIR')


def sync_control(path, version):
    with open(path, 'r', encoding='utf-8') as handle:
        text = handle.read()
    new_text, count = re.subn(r'(?m)^Version:[ \t]*\S+[ \t]*$', 'Version: %s' % version, text)
    if count != 1:
        raise SystemExit('control: expected exactly one Version: line, found %d' % count)
    if new_text != text:
        with open(path, 'w', encoding='utf-8', newline='') as handle:
            handle.write(new_text)
        return True
    return False


def sync_info_plist(path, version):
    with open(path, 'r', encoding='utf-8') as handle:
        text = handle.read()

    # CFBundleShortVersionString 紧跟自己的 <string>。
    short, short_count = re.subn(
        r'(<key>CFBundleShortVersionString</key>\s*<string>)[^<]*(</string>)',
        r'\g<1>%s\g<2>' % version, text)
    if short_count != 1:
        raise SystemExit('%s: expected one CFBundleShortVersionString, found %d' % (path, short_count))

    # CFBundleVersion 单调递增，并容纳「1.0.6-1」这种子版本：
    #     major*1000000 + minor*10000 + patch*100 + revision
    #   1.0.6 → 1000600　1.0.6-1 → 1000601　1.0.7 → 1000700
    core, _, revision = version.partition('-')
    parts = [int(p) for p in core.split('.')]
    while len(parts) < 3:
        parts.append(0)
    build = parts[0] * 1000000 + parts[1] * 10000 + parts[2] * 100 + (int(revision) if revision else 0)
    out, build_count = re.subn(
        r'(<key>CFBundleVersion</key>\s*<string>)[^<]*(</string>)',
        r'\g<1>%d\g<2>' % build, short)
    if build_count != 1:
        raise SystemExit('%s: expected one CFBundleVersion, found %d' % (path, build_count))

    if out != text:
        with open(path, 'w', encoding='utf-8', newline='') as handle:
            handle.write(out)
        return True
    return False


def sync_depiction(path, version):
    with open(path, 'r', encoding='utf-8') as handle:
        raw = handle.read()
    data = json.loads(raw)          # 先校验 JSON 本身没坏

    changed = 0
    for tab in data.get('tabs', []):
        for view in tab.get('views', []):
            if view.get('class') == 'DepictionTableTextView' and view.get('title') == 'Version':
                if view.get('text') != version:
                    view['text'] = version
                    changed += 1
    if not changed:
        return False
    with open(path, 'w', encoding='utf-8', newline='') as handle:
        json.dump(data, handle, ensure_ascii=False, indent=2)
        handle.write('\n')
    return True


def sync_diagnostic_version(path, version):
    """把源码里 `ver=X.Y.Z` 的诊断串统一改到当前版本。

    这些串会编进 dylib，是实机日志里唯一能确认真实运行版本的东西。
    漏改的话日志会一直报旧版本号（1.0.4 就漏过一次，导出的日志里全是 ver=1.0.3）。
    """
    with open(path, 'r', encoding='utf-8') as handle:
        text = handle.read()
    out, count = re.subn(r'ver=\d+\.\d+(?:\.\d+)*(?:-\d+)?', 'ver=%s' % version, text)
    if not count:
        return False
    if out != text:
        with open(path, 'w', encoding='utf-8', newline='') as handle:
            handle.write(out)
        print('%-28s %d occurrence(s) bumped' % ('Tweak.xm ver=', count))
    return out != text


def sync_dualcam_version(path, version):
    """1.0.7-5：相机双摄自己的版本串 kDualCamVersion。

    它是第三支 dylib（EchoRebornDualCam）里唯一的版本标识，会写进 [DUALCAM] 日志。
    不同步的话，日志里会出现「包是 1.0.7-5、双摄报 1.3.0」这种对不上的情况 ——
    与 1.0.6-2 给天气模块加 ver= 同步是同一个理由。
    """
    with open(path, 'r', encoding='utf-8') as handle:
        text = handle.read()
    out, count = re.subn(r'(kDualCamVersion\s*=\s*@")[^"]*(")',
                         r'\g<1>%s\g<2>' % version, text)
    if not count:
        raise SystemExit('%s: kDualCamVersion not found' % path)
    if out != text:
        with open(path, 'w', encoding='utf-8', newline='') as handle:
            handle.write(out)
        return True
    return False


def main():
    parser = argparse.ArgumentParser(description='sync the Echo Reborn version number everywhere')
    parser.add_argument('version', help='e.g. 1.0.5 or 1.0.6-1')
    parser.add_argument('--project', default=None,
                        help='path to the EchoReborn project root (auto-detected by default)')
    args = parser.parse_args()

    version = args.version.strip()
    if not re.fullmatch(r'\d+\.\d+(\.\d+)?(-\d+)?', version):
        raise SystemExit('version must look like 1.0.5 or 1.0.6-1 (got %r)' % version)

    project = find_project_root(args.project)
    print('project: %s' % project)

    targets = [
        ('control', os.path.join(project, 'control'), sync_control),
        ('prefs/Resources/Info.plist', os.path.join(project, 'prefs', 'Resources', 'Info.plist'), sync_info_plist),
        ('assets/depiction.json', os.path.join(project, 'assets', 'depiction.json'), sync_depiction),
        ('Tweak.xm ver= markers', os.path.join(project, 'Tweak.xm'), sync_diagnostic_version),
        # 1.0.6-2：天气模块是独立的 ControlCenter bundle，编译进自己那份二进制，
        # 不复用 Tweak.xm。它内部的 ver= 诊断串同样是「日志里唯一能确认真实运行版本」
        # 的东西，所以一并纳入同步，避免出现「主插件 1.0.6-2 而天气磁贴还报旧号」。
        ('modules/weather/ERWeatherModule.m ver= markers',
         os.path.join(project, 'modules', 'weather', 'ERWeatherModule.m'), sync_diagnostic_version),
        ('modules/weather/ERWeatherBridge.m ver= markers',
         os.path.join(project, 'modules', 'weather', 'ERWeatherBridge.m'), sync_diagnostic_version),
        # 1.0.7-5：相机双摄（第三支 dylib）自己的版本串。
        ('DualCam/Tweak.xm kDualCamVersion',
         os.path.join(project, 'DualCam', 'Tweak.xm'), sync_dualcam_version),
    ]

    for label, path, fn in targets:
        if not os.path.exists(path):
            raise SystemExit('missing file: %s' % path)
        changed = fn(path, version)
        print('%-28s %s' % (label, 'updated' if changed else 'already %s' % version))

    print('\nversion is %s in every place that ships it.' % version)


if __name__ == '__main__':
    main()
