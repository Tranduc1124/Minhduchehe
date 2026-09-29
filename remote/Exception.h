//
//  Exception.h
//  Cyanide
//
//  Created by seo on 4/4/26.
//

#import <mach/mach.h>
#import "RemoteCall.h"

// from pe_main.js
typedef struct {
    mach_msg_header_t       Head;
    uint64_t                NDR;
    uint32_t                exception;
    uint32_t                codeCnt;
    uint64_t                codeFirst;
    uint64_t                codeSecond;
    uint32_t                flavor;
    uint32_t                old_stateCnt;
    arm_thread_state64_internal    threadState;
    uint64_t                padding[2];
} ExceptionMessage;

typedef struct {
    mach_msg_header_t   Head;
    uint64_t            NDR;
    uint32_t            RetCode;
    uint32_t            flavor;
    uint32_t            new_stateCnt;
    arm_thread_state64_internal threadState;
} __attribute__((packed)) ExceptionReply;

mach_port_t create_exception_port(void);
void destroy_exception_port(mach_port_t exceptionPort);
bool wait_exception(mach_port_t exceptionPort, ExceptionMessage *excBuffer, int timeout, bool debug);
void reply_with_state(ExceptionMessage *exc, arm_thread_state64_internal *state);

// Reject an exception message that cannot be a live faulted thread.
// SpringBoard IPS 2026-09-26 06:21:04 (SIGKILL / CODESIGNING "Invalid Page"):
//   faultingThread pc=__getpid  lr=0x401 (FAKE_LR_TROJAN)  sp=0  x[0..28]=0
// wait_exception() accepted ANY message on the port, so a zeroed state was
// replied to as if it were the parked call thread. Do not reply without this.
bool exception_state_is_sane(ExceptionMessage *exc);
