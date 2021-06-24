;------------------------------------------------------------------------------
; @file
; Sets the CR3 register for 64-bit paging
;
; Copyright (c) 2008 - 2013, Intel Corporation. All rights reserved.<BR>
; Copyright (c) 2017 - 2020, Advanced Micro Devices, Inc. All rights reserved.<BR>
; SPDX-License-Identifier: BSD-2-Clause-Patent
;
;------------------------------------------------------------------------------

%include "Nasm.inc"

BITS    32

;
; SEV-ES #VC exception handler support
;
; #VC handler local variable locations
;
%define VC_CPUID_RESULT_EAX         0
%define VC_CPUID_RESULT_EBX         4
%define VC_CPUID_RESULT_ECX         8
%define VC_CPUID_RESULT_EDX        12
%define VC_GHCB_MSR_EDX            16
%define VC_GHCB_MSR_EAX            20
%define VC_CPUID_REQUEST_REGISTER  24
%define VC_CPUID_FUNCTION          28

; #VC handler total local variable size
;
%define VC_VARIABLE_SIZE           32

; #VC handler GHCB CPUID request/response protocol values
;
%define GHCB_CPUID_REQUEST          4
%define GHCB_CPUID_RESPONSE         5
%define GHCB_CPUID_REGISTER_SHIFT  30
%define CPUID_INSN_LEN              2


%define SEV_GHCB_MSR                0xc0010130
%define SEV_STATUS_MSR              0xc0010131

; The #VC was not for CPUID
%define TERM_VC_NOT_CPUID           1

; The unexpected response code
%define TERM_UNEXPECTED_RESP_CODE   2

; SNP page state change failure
%define TERM_PAGE_STATE_CHANAGE     3

; Hypervisor does not support SEV-SNP feature
%define TERM_HV_UNSUPPORTED_FEATURE 4

; SEV-SNP guest is not launched at VMPL-0
%define TERM_SNP_NOT_VMPL0          5

; The #VC is not for PVALIDATE
%define TERM_VC_NOT_PVALIDATE       6

; GHCB SEV Information MSR protocol
%define GHCB_SEV_INFORMATION_REQUEST        2
%define GHCB_SEV_INFORMATION_RESPONSE       1

; GHCB Page Invalidate request and response protocol values
;
%define GHCB_PAGE_STATE_CHANGE_REQUEST      20
%define GHCB_PAGE_STATE_CHANGE_RESPONSE     21
%define GHCB_PAGE_STATE_SHARED              2

; GHCB Hypervisor features MSR protocol
%define GHCB_HYPERVISOR_FEATURES_REQUEST    128
%define GHCB_HYPERVISOR_FEATURES_RESPONSE   129

; Macro is used to issue the MSR protocol based VMGEXIT. The caller is
; responsible to populate values in the EDX:EAX registers. After the vmmcall
; returns, it verifies that the response code matches with the expected
; code. If it does not match then terminate the guest. The result of request
; is returned in the EDX:EAX.
;
; args 1:Request code, 2: Response code
%macro VmgExit 2
    ;
    ; Add request code:
    ;   GHCB_MSR[11:0]  = Request code
    or      eax, %1

    mov     ecx, SEV_GHCB_MSR
    wrmsr

    ; Issue VMGEXIT - NASM doesn't support the vmmcall instruction in 32-bit
    ; mode, so work around this by temporarily switching to 64-bit mode.
    ;
BITS    64
    rep     vmmcall
BITS    32

    mov     ecx, SEV_GHCB_MSR
    rdmsr

    ;
    ; Verify the reponse code, if it does not match then request to terminate
    ;   GHCB_MSR[11:0]  = Response code
    mov     ecx, eax
    and     ecx, 0xfff
    cmp     ecx, %2
    jne     SevEsUnexpectedRespTerminate
%endmacro

; Macro to terminate the guest using the VMGEXIT.
; arg 1: reason code
%macro TerminateVmgExit 1
    mov     eax, %1
    ;
    ; Use VMGEXIT to request termination. At this point the reason code is
    ; located in EAX, so shift it left 16 bits to the proper location.
    ;
    ; EAX[11:0]  => 0x100 - request termination
    ; EAX[15:12] => 0x1   - OVMF
    ; EAX[23:16] => 0xXX  - REASON CODE
    ;
    shl     eax, 16
    or      eax, 0x1100
    xor     edx, edx
    mov     ecx, SEV_GHCB_MSR
    wrmsr
    ;
    ; Issue VMGEXIT - NASM doesn't support the vmmcall instruction in 32-bit
    ; mode, so work around this by temporarily switching to 64-bit mode.
    ;
BITS    64
    rep     vmmcall
BITS    32

    ;
    ; We shouldn't come back from the VMGEXIT, but if we do, just loop.
    ;
%%TerminateHlt:
    hlt
    jmp     %%TerminateHlt
%endmacro

; Terminate the guest due to unexpected response code.
SevEsUnexpectedRespTerminate:
    TerminateVmgExit    TERM_UNEXPECTED_RESP_CODE

; Check whether we're booted under the VMPL-0.
;
; There is no straightforward way to query the current VMPL level. The simplest
; method is to use the PVALIDATE instruction to change the page state. If its
; not a VMPL-0 guest then PVALIDATE will cause #GP.
;
CheckSnpVmpl0:
    ; This routine is part of the ROM, and should have been validated by the SNP
    ; guest launch sequence. So its safe to re-validate the page containing
    ; this routine.
    mov     eax, ADDR_OF(CheckSnpVmpl0)
    mov     ecx, 0
    mov     edx, 1
    PVALIDATE

    ; We will reach here only if we are running at VMPL-0.

    OneTimeCallRet    CheckSnpVmpl0

; Check if Secure Encrypted Virtualization (SEV) features are enabled.
;
; Register usage is tight in this routine, so multiple calls for the
; same CPUID and MSR data are performed to keep things simple.
;
; Modified:  EAX, EBX, ECX, EDX, ESP
;
; If SEV is enabled then EAX will be at least 32.
; If SEV is disabled then EAX will be zero.
;
CheckSevFeatures:
    ; Set the first byte of the workarea to zero to communicate to the SEC
    ; phase that SEV-ES is not enabled. If SEV-ES is enabled, the CPUID
    ; instruction will trigger a #VC exception where the first byte of the
    ; workarea will be set to one or, if CPUID is not being intercepted,
    ; the MSR check below will set the first byte of the workarea to one.
    mov     byte[SEV_ES_WORK_AREA], 0

    ;
    ; Set up exception handlers to check for SEV-ES
    ;   Load temporary RAM stack based on PCDs (see SevEsIdtVmmComm for
    ;   stack usage)
    ;   Establish exception handlers
    ;
    mov       esp, SEV_ES_VC_TOP_OF_STACK
    mov       eax, ADDR_OF(Idtr)
    lidt      [cs:eax]

    ; Check if we have a valid (0x8000_001F) CPUID leaf
    ;   CPUID raises a #VC exception if running as an SEV-ES guest
    mov       eax, 0x80000000
    cpuid

    ; This check should fail on Intel or Non SEV AMD CPUs. In future if
    ; Intel CPUs supports this CPUID leaf then we are guranteed to have exact
    ; same bit definition.
    cmp       eax, 0x8000001f
    jl        NoSev

    ; Check for SEV memory encryption feature:
    ; CPUID  Fn8000_001F[EAX] - Bit 1
    ;   CPUID raises a #VC exception if running as an SEV-ES guest
    mov       eax, 0x8000001f
    cpuid
    bt        eax, 1
    jnc       NoSev

    ; Check if SEV memory encryption is enabled
    ;  MSR_0xC0010131 - Bit 0 (SEV enabled)
    mov       ecx, SEV_STATUS_MSR
    rdmsr
    bt        eax, 0
    jnc       NoSev

    ; Check if we're SEV-SNP guest and booted under VMPL-0.
    ;
    ; This check should happen here because the PVALIDATE instruction
    ; used in the check will cause an exception. The IDT is active
    ; during the CheckSevFeatures only.
    ;
    bt        eax, 2
    jnc       SkipCheckSnpVmpl0
    OneTimeCall     CheckSnpVmpl0

SkipCheckSnpVmpl0:
    ; Check for SEV-ES memory encryption feature:
    ; CPUID  Fn8000_001F[EAX] - Bit 3
    ;   CPUID raises a #VC exception if running as an SEV-ES guest
    mov       eax, 0x8000001f
    cpuid
    bt        eax, 3
    jnc       GetSevEncBit

    ; Check if SEV-ES is enabled
    ;  MSR_0xC0010131 - Bit 1 (SEV-ES enabled)
    mov       ecx, SEV_STATUS_MSR
    rdmsr
    bt        eax, 1
    jnc       GetSevEncBit

    ; Set the first byte of the workarea to one to communicate to the SEC
    ; phase that SEV-ES is enabled.
    mov       byte[SEV_ES_WORK_AREA], 1

GetSevEncBit:
    ; Get pte bit position to enable memory encryption
    ; CPUID Fn8000_001F[EBX] - Bits 5:0
    ;
    and       ebx, 0x3f
    mov       eax, ebx

    ; The encryption bit position is always above 31
    sub       ebx, 32
    jns       SevSaveMask

    ; Encryption bit was reported as 31 or below, enter a HLT loop
SevEncBitLowHlt:
    cli
    hlt
    jmp       SevEncBitLowHlt

SevSaveMask:
    xor       edx, edx
    bts       edx, ebx

    mov       dword[SEV_ES_WORK_AREA_ENC_MASK], 0
    mov       dword[SEV_ES_WORK_AREA_ENC_MASK + 4], edx
    jmp       SevExit

NoSev:
    ;
    ; Perform an SEV-ES sanity check by seeing if a #VC exception occurred.
    ;
    cmp       byte[SEV_ES_WORK_AREA], 0
    jz        NoSevPass

    ;
    ; A #VC was received, yet CPUID indicates no SEV-ES support, something
    ; isn't right.
    ;
NoSevEsVcHlt:
    cli
    hlt
    jmp       NoSevEsVcHlt

NoSevPass:
    xor       eax, eax

SevExit:
    ;
    ; Clear exception handlers and stack
    ;
    push      eax
    mov       eax, ADDR_OF(IdtrClear)
    lidt      [cs:eax]
    pop       eax
    mov       esp, 0

    OneTimeCallRet CheckSevFeatures

; The version 2 of GHCB specification added the support to query the hypervisor
; features. If the GHCB version is >=2 then read the hypervisor features and
; verify that SEV-SNP feature is supported.
;
CheckSnpHypervisorFeatures:
    ; Get the SEV Information
    xor     eax, eax
    xor     edx, edx

    VmgExit GHCB_SEV_INFORMATION_REQUEST, GHCB_SEV_INFORMATION_RESPONSE

    ;
    ; SEV Information Response GHCB MSR
    ;   GHCB_MSR[63:48] = Maximum protocol version
    ;   GHCB_MSR[47:32] = Minimum protocol version
    ;
    shr     edx, 16
    cmp     edx, 2
    jl      SevSnpUnsupportedFeature

    ; Get the hypervisor features
    xor     eax, eax
    xor     edx, edx

    VmgExit GHCB_HYPERVISOR_FEATURES_REQUEST, GHCB_HYPERVISOR_FEATURES_RESPONSE

    ;
    ; Hypervisor features reponse
    ;   GHCB_MSR[63:12] = Features bitmap
    ;       BIT0        = SEV-SNP Supported
    ;
    shr     eax, 12
    bt      eax, 0
    jnc     SevSnpUnsupportedFeature

CheckSnpHypervisorFeaturesDone:
    OneTimeCallRet CheckSnpHypervisorFeatures

; If its an SEV-SNP guest then use the page state change VMGEXIT to invalidate
; the GHCB page.
;
; Modified:  EAX, EBX, ECX, EDX
;
InvalidateGHCBPage:
    ; Check if SEV-SNP is enabled
    ;  MSR_0xC0010131 - Bit 2 (SEV-SNP enabled)
    mov       ecx, SEV_STATUS_MSR
    rdmsr
    bt        eax, 2
    jnc       InvalidateGHCBPageDone

    ; Verify that SEV-SNP feature is supported by the hypervisor.
    OneTimeCall   CheckSnpHypervisorFeatures

    ; Use PVALIDATE instruction to invalidate the page
    mov     eax, GHCB_BASE
    mov     ecx, 0
    mov     edx, 0
    PVALIDATE

    ; Save the carry flag to be use later.
    setc    dl

    ; If PVALIDATE fail then abort the launch.
    cmp     eax, 0
    jne     SevSnpPageStateFailureTerminate

    ; Check the carry flag to determine if RMP entry was updated.
    cmp     dl, 0
    jne     SevSnpPageStateFailureTerminate

    ; Ask hypervisor to change the page state to shared using the
    ; Page State Change VMGEXIT.
    ;
    ; Setup GHCB MSR
    ;   GHCB_MSR[55:52] = Page Operation
    ;   GHCB_MSR[51:12] = Guest Physical Frame Number
    ;
    mov     eax, (GHCB_BASE >> 12)
    shl     eax, 12
    mov     edx, (GHCB_PAGE_STATE_SHARED << 20)

    VmgExit  GHCB_PAGE_STATE_CHANGE_REQUEST, GHCB_PAGE_STATE_CHANGE_RESPONSE

    ;
    ; Response GHCB MSR
    ;   GHCB_MSR[63:12] = Error code
    ;
    cmp     edx, 0
    jnz     SevSnpPageStateFailureTerminate

InvalidateGHCBPageDone:
    OneTimeCallRet InvalidateGHCBPage

; Terminate the SEV-SNP guest due to the page state change failure
SevSnpPageStateFailureTerminate:
    TerminateVmgExit   TERM_PAGE_STATE_CHANAGE

; Terminate the SEV-SNP guest because hypervisor does not support
; the SEV-SNP feature
SevSnpUnsupportedFeature:
    TerminateVmgExit   TERM_HV_UNSUPPORTED_FEATURE


; Check if Secure Encrypted Virtualization - Encrypted State (SEV-ES) feature
; is enabled.
;
; Modified:  EAX
;
; If SEV-ES is enabled then EAX will be non-zero.
; If SEV-ES is disabled then EAX will be zero.
;
IsSevEsEnabled:
    xor       eax, eax

    ; During CheckSevFeatures, the SEV_ES_WORK_AREA was set to 1 if
    ; SEV-ES is enabled.
    cmp       byte[SEV_ES_WORK_AREA], 1
    jne       SevEsDisabled

    mov       eax, 1

SevEsDisabled:
    OneTimeCallRet IsSevEsEnabled

; Start handling of #GP exception handling routines
;
SevEsIdtNotPvalidate:
    TerminateVmgExit TERM_VC_NOT_PVALIDATE
    iret

SevSnpGpException:
    ;
    ; If we're here, then we are an SEV-SNP guest and this
    ; was triggered by a PVALIDATE instruction.
    ;
    ; Verify that its an PVALIDATE instruction
    ; The exception stack looks like this:
    ;     +---------+
    ;     | ....    |
    ;     | eip     |
    ;     | err code|
    ;     +---------+
    pop     ebx
    pop     ebx
    mov     ecx, [ebx]
    cmp     ecx, 0xff010ff2       ; Compare EIP with PVALIDATE menomics
    jne     SevEsIdtNotPvalidate

    ; The #GP was triggered by the PVALIDATE instruction, this will happen
    ; only when we're not running at VMPL-0
    ;
    TerminateVmgExit TERM_SNP_NOT_VMPL0
    iret

; Start of #VC exception handling routines
;

SevEsIdtNotCpuid:
    TerminateVmgExit TERM_VC_NOT_CPUID
    iret

    ;
    ; Total stack usage for the #VC handler is 44 bytes:
    ;   - 12 bytes for the exception IRET (after popping error code)
    ;   - 32 bytes for the local variables.
    ;
SevEsIdtVmmComm:
    ;
    ; If we're here, then we are an SEV-ES guest and this
    ; was triggered by a CPUID instruction
    ;
    ; Set the first byte of the workarea to one to communicate that
    ; a #VC was taken.
    mov     byte[SEV_ES_WORK_AREA], 1

    pop     ecx                     ; Error code
    cmp     ecx, 0x72               ; Be sure it was CPUID
    jne     SevEsIdtNotCpuid

    ; Set up local variable room on the stack
    ;   CPUID function         : + 28
    ;   CPUID request register : + 24
    ;   GHCB MSR (EAX)         : + 20
    ;   GHCB MSR (EDX)         : + 16
    ;   CPUID result (EDX)     : + 12
    ;   CPUID result (ECX)     : + 8
    ;   CPUID result (EBX)     : + 4
    ;   CPUID result (EAX)     : + 0
    sub     esp, VC_VARIABLE_SIZE

    ; Save the CPUID function being requested
    mov     [esp + VC_CPUID_FUNCTION], eax

    ; The GHCB CPUID protocol uses the following mapping to request
    ; a specific register:
    ;   0 => EAX, 1 => EBX, 2 => ECX, 3 => EDX
    ;
    ; Set EAX as the first register to request. This will also be used as a
    ; loop variable to request all register values (EAX to EDX).
    xor     eax, eax
    mov     [esp + VC_CPUID_REQUEST_REGISTER], eax

    ; Save current GHCB MSR value
    mov     ecx, SEV_GHCB_MSR
    rdmsr
    mov     [esp + VC_GHCB_MSR_EAX], eax
    mov     [esp + VC_GHCB_MSR_EDX], edx

NextReg:
    ;
    ; Setup GHCB MSR
    ;   GHCB_MSR[63:32] = CPUID function
    ;   GHCB_MSR[31:30] = CPUID register
    ;   GHCB_MSR[11:0]  = CPUID request protocol
    ;
    mov     eax, [esp + VC_CPUID_REQUEST_REGISTER]
    cmp     eax, 4
    jge     VmmDone

    shl     eax, GHCB_CPUID_REGISTER_SHIFT
    mov     edx, [esp + VC_CPUID_FUNCTION]

    VmgExit GHCB_CPUID_REQUEST, GHCB_CPUID_RESPONSE

    ;
    ; Response GHCB MSR
    ;   GHCB_MSR[63:32] = CPUID register value
    ;   GHCB_MSR[31:30] = CPUID register
    ;   GHCB_MSR[11:0]  = CPUID response protocol
    ;

    ; Save returned value
    shr     eax, GHCB_CPUID_REGISTER_SHIFT
    mov     [esp + eax * 4], edx

    ; Next register
    inc     word [esp + VC_CPUID_REQUEST_REGISTER]

    jmp     NextReg

VmmDone:
    ;
    ; At this point we have all CPUID register values. Restore the GHCB MSR,
    ; set the return register values and return.
    ;
    mov     eax, [esp + VC_GHCB_MSR_EAX]
    mov     edx, [esp + VC_GHCB_MSR_EDX]
    mov     ecx, SEV_GHCB_MSR
    wrmsr

    mov     eax, [esp + VC_CPUID_RESULT_EAX]
    mov     ebx, [esp + VC_CPUID_RESULT_EBX]
    mov     ecx, [esp + VC_CPUID_RESULT_ECX]
    mov     edx, [esp + VC_CPUID_RESULT_EDX]

    add     esp, VC_VARIABLE_SIZE

    ; Update the EIP value to skip over the now handled CPUID instruction
    ; (the CPUID instruction has a length of 2)
    add     word [esp], CPUID_INSN_LEN
    iret

ALIGN   2

Idtr:
    dw      IDT_END - IDT_BASE - 1  ; Limit
    dd      ADDR_OF(IDT_BASE)       ; Base

IdtrClear:
    dw      0                       ; Limit
    dd      0                       ; Base

ALIGN   16

;
; The Interrupt Descriptor Table (IDT)
;   This will be used to determine if SEV-ES is enabled.  Upon execution
;   of the CPUID instruction, a VMM Communication Exception will occur.
;   This will tell us if SEV-ES is enabled.  We can use the current value
;   of the GHCB MSR to determine the SEV attributes.
;
IDT_BASE:
;
; Vectors 0 - 12 (No handlers)
;
%rep 13
    dw      0                                    ; Offset low bits 15..0
    dw      0x10                                 ; Selector
    db      0                                    ; Reserved
    db      0x8E                                 ; Gate Type (IA32_IDT_GATE_TYPE_INTERRUPT_32)
    dw      0                                    ; Offset high bits 31..16
%endrep
;
; Vector 13 (GP Exception)
;
    dw      (ADDR_OF(SevSnpGpException) & 0xffff)  ; Offset low bits 15..0
    dw      0x10                                 ; Selector
    db      0                                    ; Reserved
    db      0x8E                                 ; Gate Type (IA32_IDT_GATE_TYPE_INTERRUPT_32)
    dw      (ADDR_OF(SevSnpGpException) >> 16)   ; Offset high bits 31..16
;
; Vectors 14 - 28 (No handlers)
;
%rep 15
    dw      0                                    ; Offset low bits 15..0
    dw      0x10                                 ; Selector
    db      0                                    ; Reserved
    db      0x8E                                 ; Gate Type (IA32_IDT_GATE_TYPE_INTERRUPT_32)
    dw      0                                    ; Offset high bits 31..16
%endrep

;
; Vector 29 (VMM Communication Exception)
;
    dw      (ADDR_OF(SevEsIdtVmmComm) & 0xffff)  ; Offset low bits 15..0
    dw      0x10                                 ; Selector
    db      0                                    ; Reserved
    db      0x8E                                 ; Gate Type (IA32_IDT_GATE_TYPE_INTERRUPT_32)
    dw      (ADDR_OF(SevEsIdtVmmComm) >> 16)     ; Offset high bits 31..16
;
; Vectors 30 - 31 (No handlers)
;
%rep 2
    dw      0                                    ; Offset low bits 15..0
    dw      0x10                                 ; Selector
    db      0                                    ; Reserved
    db      0x8E                                 ; Gate Type (IA32_IDT_GATE_TYPE_INTERRUPT_32)
    dw      0                                    ; Offset high bits 31..16
%endrep
IDT_END: