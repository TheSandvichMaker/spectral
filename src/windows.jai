kernel32 :: #foreign_system_library "kernel32";
user32   :: #foreign_system_library "user32";

CONDITION_VARIABLE :: struct
{
    value: *void;
}
CONDITION_VARIABLE_INIT :: CONDITION_VARIABLE.{null};

InitializeConditionVariable :: (ConditionVariable: *CONDITION_VARIABLE) #foreign kernel32;
SleepConditionVariableCS    :: (ConditionVariable: *CONDITION_VARIABLE, CriticalSection: *CRITICAL_SECTION, dwMilliseconds: u32) -> BOOL #foreign kernel32;
SleepConditionVariableSRW   :: (ConditionVariable: *CONDITION_VARIABLE, SRWLock: *SRWLOCK, dwMilliseconds: u32, Flags: u32) -> BOOL #foreign kernel32;
WakeAllConditionVariable    :: (ConditionVariable: *CONDITION_VARIABLE) #foreign kernel32;
WakeConditionVariable       :: (ConditionVariable: *CONDITION_VARIABLE) #foreign kernel32;

SRWLOCK :: struct
{
    value: *void;
}
SRWLOCK_INIT :: SRWLOCK.{null};

AcquireSRWLockExclusive    :: (SRWLock: *SRWLOCK) #foreign kernel32;
AcquireSRWLockShared       :: (SRWLock: *SRWLOCK) #foreign kernel32;
InitializeSRWLock          :: (SRWLock: *SRWLOCK) #foreign kernel32;
ReleaseSRWLockExclusive    :: (SRWLock: *SRWLOCK) #foreign kernel32;
ReleaseSRWLockShared       :: (SRWLock: *SRWLOCK) #foreign kernel32;
TryAcquireSRWLockExclusive :: (SRWLock: *SRWLOCK) -> BOOL #foreign kernel32;
TryAcquireSRWLockShared    :: (SRWLock: *SRWLOCK) -> BOOL #foreign kernel32;

GetMessageA :: (msg: *MSG, hwnd: HWND, wMsgFilterMin: u32, wMsgFilterMax: u32) -> BOOL #foreign user32 #deprecated "Use GetMessageW instead.";
GetMessageW :: (msg: *MSG, hwnd: HWND, wMsgFilterMin: u32, wMsgFilterMax: u32) -> BOOL #foreign user32;

TIMERPROC :: #type (hwnd: HWND, uMsg: u32, idEvent: u64, dwTime: u32) #c_call;
SetTimer  :: (hwnd: HWND, nIDEvent: u64, uElapse: u32, lpTimerFunc: TIMERPROC) -> u64 #foreign user32;

SetCursorPos :: (x: s32, y: s32) -> BOOL #foreign user32;
