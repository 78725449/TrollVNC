/*
 This file is part of SuperPhone
 Copyright (c) 2025 82Flex <82flex@gmail.com> and contributors

 This program is free software; you can redistribute it and/or modify
 it under the terms of the GNU General Public License version 2
 as published by the Free Software Foundation.

 This program is distributed in the hope that it will be useful,
 but WITHOUT ANY WARRANTY; without even the implied warranty of
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
 GNU General Public License for more details.

 You should have received a copy of the GNU General Public License
 along with this program. If not, see <https://www.gnu.org/licenses/>.
*/

#import <TargetConditionals.h>

#if !TARGET_OS_SIMULATOR

#import <Foundation/Foundation.h>

#ifdef __cplusplus
extern "C" {
#endif

#import "libproc.h"
#import "kern_memorystatus.h"

#ifdef __cplusplus
}
#endif

NS_INLINE
void BypassJetsamByProcess(pid_t me, BOOL critical) {
    int rc;
    memorystatus_priority_properties_t props = {JETSAM_PRIORITY_CRITICAL, 0};
    rc = memorystatus_control(MEMORYSTATUS_CMD_SET_PRIORITY_PROPERTIES, me, 0, &props, sizeof(props));
    if (critical && rc < 0) {
        perror("memorystatus_control");
        exit(rc);
    }
    rc = memorystatus_control(MEMORYSTATUS_CMD_SET_JETSAM_HIGH_WATER_MARK, me, -1, NULL, 0);
    if (critical && rc < 0) {
        perror("memorystatus_control");
        exit(rc);
    }
    rc = memorystatus_control(MEMORYSTATUS_CMD_SET_JETSAM_TASK_LIMIT, me, 0x400, NULL, 0);
    if (critical && rc < 0) {
        perror("memorystatus_control");
        exit(rc);
    }
    rc = memorystatus_control(MEMORYSTATUS_CMD_SET_PROCESS_IS_MANAGED, me, 0, NULL, 0);
    if (critical && rc < 0) {
        perror("memorystatus_control");
        exit(rc);
    }
    rc = memorystatus_control(MEMORYSTATUS_CMD_SET_PROCESS_IS_FREEZABLE, me, 0, NULL, 0);
    if (critical && rc < 0) {
        perror("memorystatus_control");
        exit(rc);
    }
    rc = proc_track_dirty(me, 0);
    if (critical && rc != 0) {
        perror("proc_track_dirty");
        exit(rc);
    }
}

// marked as a constructor with the highest priority
__attribute__((constructor(101))) static void BypassJetsam(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^(void) {
        pid_t me = getpid();
        BypassJetsamByProcess(me, YES);
    });
}

#endif
