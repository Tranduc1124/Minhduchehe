#import <Foundation/Foundation.h>
#import <mach/mach.h>
#import <mach/task_info.h>
#import <mach-o/dyld_images.h>
#import <stdio.h>
#import <stdlib.h>
#import <string.h>
#import <limits.h>
#import <sys/sysctl.h>
#import <errno.h>
#import "pid.h"
#import "../DSMemory.h"

#pragma mark - Global task (set by GetGameModule_Base)

mach_port_t get_task = MACH_PORT_NULL;

#pragma mark - PID (sysctl, no libproc)

pid_t GetGameProcesspidExact(const char *GameProcessName) {
    if (!GameProcessName || !GameProcessName[0]) return -1;

    size_t length = 0;
    static const int name[] = { CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0 };
    int err = sysctl((int *)name, (sizeof(name) / sizeof(*name)) - 1, NULL, &length, NULL, 0);
    if (err == -1) err = errno;
    if (err != 0) return -1;

    struct kinfo_proc *procBuffer = (struct kinfo_proc *)malloc(length);
    if (!procBuffer) return -1;

    err = sysctl((int *)name, (sizeof(name) / sizeof(*name)) - 1, procBuffer, &length, NULL, 0);
    if (err == -1) {
        free(procBuffer);
        return -1;
    }

    int count = (int)(length / sizeof(struct kinfo_proc));
    for (int i = 0; i < count; i++) {
        const char *procname = procBuffer[i].kp_proc.p_comm;
        // Exact match only: "FreeFire" must not match "FreeFireMAX".
        if (procname && strcmp(procname, GameProcessName) == 0) {
            pid_t pid = procBuffer[i].kp_proc.p_pid;
            free(procBuffer);
            return pid;
        }
    }
    free(procBuffer);
    return -1;
}

pid_t GetGameProcesspid(char *GameProcessName) {
    return GetGameProcesspidExact(GameProcessName);
}

#pragma mark - Module base (dyld, chính xác theo image name)

uintptr_t GetGameModule_Base(char *GameProcessName) {
    pid_t pid = GetGameProcesspid(GameProcessName);
    if (pid == -1)
        return 0;

    get_task = get_task_for_PID(pid);
    if (get_task == MACH_PORT_NULL)
        return 0;

    const char *imageTry[] = {
        "UnityFramework",
        GameProcessName ? GameProcessName : "",
    };
    uintptr_t base = 0;
    const char *picked = nullptr;
    for (size_t i = 0; i < sizeof(imageTry) / sizeof(imageTry[0]); i++) {
        if (!imageTry[i] || !imageTry[i][0]) continue;
        base = (uintptr_t)get_image_base_address(get_task, (char *)imageTry[i]);
        if (base != 0) {
            picked = imageTry[i];
            break;
        }
    }
    if (base == 0)
        return 0;

    (void)picked;
    return base;
}

#pragma mark - Read/Write (dùng get_task, không leak)

// FIX "aim không tác dụng": trên jailed IPA task_for_pid fail → get_task NULL →
// mọi WriteAddr (aim rotation, AA kill, Brutal…) fail âm thầm trong khi ds_read
// vẫn chạy tốt qua kernel remap. Nối cả read lẫn write vào DSMemory kernel path.
bool _read(long addr, void *buffer, int len) {
    if (!isVaildPtr(static_cast<uintptr_t>(addr)) || !buffer || len <= 0) return false;
    if (ds_attached()) return ds_read((uint64_t)addr, buffer, (size_t)len);
    if (get_task == MACH_PORT_NULL) return false;
    mach_vm_size_t out_size = 0;
    kern_return_t kr = mach_vm_read_overwrite(get_task, (mach_vm_address_t)addr, (mach_vm_size_t)len, (mach_vm_address_t)buffer, &out_size);
    return (kr == KERN_SUCCESS && out_size == (mach_vm_size_t)len);
}

bool _write(long addr, const void *buffer, int len) {
    if (!isVaildPtr(static_cast<uintptr_t>(addr)) || !buffer || len <= 0) return false;
    if (ds_attached()) return ds_write((uint64_t)addr, buffer, (size_t)len);
    if (get_task == MACH_PORT_NULL) return false;
    kern_return_t kr = mach_vm_write(get_task, (mach_vm_address_t)addr, (pointer_t)buffer, (mach_msg_type_number_t)len);
    return (kr == KERN_SUCCESS);
}

#pragma mark - dyld structures

struct dyld_uuid_info64 {
    mach_vm_address_t    imageLoadAddress;
    uuid_t               imageUUID;
};

struct dyld_image_info64 {
    mach_vm_address_t    imageLoadAddress;
    mach_vm_address_t    imageFilePath;
    mach_vm_size_t       imageFileModDate;
};

struct dyld_all_image_infos64 {
    uint32_t version;
    uint32_t infoArrayCount;
    mach_vm_address_t infoArray;
    dyld_image_notifier  notification;
    bool                 processDetachedFromSharedRegion;
    bool libSystemInitialized;
    mach_vm_address_t            dyldImageLoadAddress;
    mach_vm_address_t            jitInfo;
    mach_vm_address_t            dyldVersion;
    mach_vm_address_t            errorMessage;
    uint64_t                    terminationFlags;
    mach_vm_address_t            coreSymbolicationShmPage;
    uint64_t                    systemOrderFlag;
    uint64_t                    uuidArrayCount;
    mach_vm_address_t            uuidArray;
    mach_vm_address_t            dyldAllImageInfosAddress;
    uint64_t                    initialImageCount;
    uint64_t                    errorKind;
    mach_vm_address_t            errorClientOfDylibPath;
    mach_vm_address_t            errorTargetDylibPath;
    mach_vm_address_t            errorSymbol;
    uint64_t                    sharedCacheSlide;
};

mach_port_t get_task_for_PID(pid_t pid)
{
    mach_port_t task;
    kern_return_t kr = task_for_pid(mach_task_self(), pid, &task);
    if (kr == KERN_SUCCESS)
    {
        return task;
    }

    return MACH_PORT_NULL;
}

pid_t get_pid_by_name(const char *keyword)
{
    int count = proc_listallpids(NULL, 0);
    if (count <= 0) {
        return -1;
    }

    // Clang on the macos-15 runner rejects C++ variable-length arrays under
    // -Werror, so the pid buffer is allocated instead of declared as pids[count].
    pid_t *pids = (pid_t *)malloc((size_t)count * sizeof(pid_t));
    if (!pids) {
        return -1;
    }

    int actual = proc_listallpids(pids, (int)((size_t)count * sizeof(pid_t)));
    if (actual > 0) {
        count = actual;
    }

    pid_t found = -1;
    for (int i = 0; i < count; i++)
    {
        char name[1000];
        proc_name(pids[i], name, sizeof(name));
        if (strstr(name, keyword) != NULL)
        {
            found = pids[i];
            break;
        }
    }

    free(pids);
    return found;
}

task_t get_task_by_pid(pid_t pid)
{
    task_port_t psDefault;
    task_port_t psDefault_control;

    task_array_t tasks;
    mach_msg_type_number_t numTasks;
    kern_return_t kr;

    host_t self_host = mach_host_self();
    kr = processor_set_default(self_host, &psDefault);
    if (kr != KERN_SUCCESS)
    {
        fprintf(stderr, "Error in processor_set_default: %x\n", kr);
        return MACH_PORT_NULL;
    }

    kr = host_processor_set_priv(self_host, psDefault, &psDefault_control);
    if (kr != KERN_SUCCESS)
    {
        fprintf(stderr, "Error in host_processor_set_priv: %x\n", kr);
        return MACH_PORT_NULL;
    }

    kr = processor_set_tasks(psDefault_control, &tasks, &numTasks);
    if (kr != KERN_SUCCESS) {
        fprintf(stderr, "Error in processor_set_tasks: %x\n", kr);
        return MACH_PORT_NULL;
    }

    for (int i = 0; i < numTasks; i++)
    {
        int task_pid;
        kr = pid_for_task(tasks[i], &task_pid);
        if (kr != KERN_SUCCESS) {
            continue;
        }

        if (task_pid == pid) return tasks[i];
    }

    return MACH_PORT_NULL;
}

mach_vm_address_t get_image_base_address(mach_port_t task, const char *image_name)
{
    task_dyld_info_data_t dyld_info;
    mach_msg_type_number_t count = TASK_DYLD_INFO_COUNT;
    kern_return_t kr = task_info(task, TASK_DYLD_INFO, (task_info_t)&dyld_info, &count);
    if (kr != KERN_SUCCESS)
    {
        fprintf(stderr, "task_info failed: %s\n", mach_error_string(kr));
        return 0;
    }

    struct dyld_all_image_infos64 infos;
    vm_size_t size = sizeof(infos);
    mach_msg_type_number_t read_size = 0;
    vm_offset_t read_mem = 0;

    kr = vm_read(task, (vm_address_t)dyld_info.all_image_info_addr, size, &read_mem, &read_size);
    if (kr != KERN_SUCCESS || read_size < sizeof(infos))
    {
        fprintf(stderr, "vm_read for dyld_all_image_infos64 failed: %s\n", mach_error_string(kr));
        return 0;
    }
    memcpy(&infos, (void *)read_mem, sizeof(infos));
    vm_deallocate(mach_task_self(), read_mem, read_size);

    uint32_t image_count = infos.infoArrayCount;
    mach_vm_address_t info_array_addr = infos.infoArray;
    vm_size_t image_info_size = image_count * sizeof(struct dyld_image_info64);
    struct dyld_image_info64 *image_infos = (struct dyld_image_info64 *)malloc(image_info_size);
    if (!image_infos) return 0;

    read_mem = 0;
    read_size = 0;
    kr = vm_read(task, (vm_address_t)info_array_addr, image_info_size, &read_mem, &read_size);
    if (kr != KERN_SUCCESS || read_size < image_info_size)
    {
        fprintf(stderr, "vm_read for image infos failed: %s\n", mach_error_string(kr));
        free(image_infos);
        return 0;
    }
    memcpy(image_infos, (void *)read_mem, image_info_size);
    vm_deallocate(mach_task_self(), read_mem, read_size);

    for (uint32_t i = 0; i < image_count; ++i)
    {
        char path_buffer[PATH_MAX] = {0};
        read_mem = 0;
        read_size = 0;
        kr = vm_read(task, (vm_address_t)image_infos[i].imageFilePath, PATH_MAX, &read_mem, &read_size);
        if (kr == KERN_SUCCESS)
        {
            size_t to_copy = read_size > PATH_MAX ? PATH_MAX : read_size;
            memcpy(path_buffer, (void *)read_mem, to_copy);
            vm_deallocate(mach_task_self(), read_mem, read_size);
        }

        if (kr == KERN_SUCCESS && strstr(path_buffer, image_name))
        {
            mach_vm_address_t base = image_infos[i].imageLoadAddress;
            free(image_infos);
            return base;
        }
    }

    free(image_infos);
    return 0;
}
