# 诊断：Python 3.13 上两条异步中断通道的实际效力（复刻 PyEngine.cpp 线程结构）
# 通道 A = Py_AddPendingCall（现产线通道，真机双失效）
# 通道 B = PyThreadState_SetAsyncExc + 调用线程持 GIL（拟议修复通道）
import ctypes, threading, time, sys
print(f'python = {sys.version}', flush=True)

cdll = ctypes.CDLL(None)
pydll = ctypes.PyDLL(None)

GetThisThreadState = pydll.PyGILState_GetThisThreadState
GetThisThreadState.restype = ctypes.c_void_p
GetThisThreadState.argtypes = []

case_b = {}
box_b = {'ready': threading.Event()}
box_a = {'ready': threading.Event()}

def case_a_worker():
    AddPending = cdll.Py_AddPendingCall
    AddPending.restype = ctypes.c_int
    AddPending.argtypes = [ctypes.c_void_p, ctypes.c_void_p]
    PyExc = ctypes.c_void_p.in_dll(cdll, 'PyExc_KeyboardInterrupt')
    PyErr_SetNone = cdll.PyErr_SetNone
    PyErr_SetNone.restype = None
    PyErr_SetNone.argtypes = [ctypes.c_void_p]
    @ctypes.PYFUNCTYPE(ctypes.c_int, ctypes.c_void_p)
    def raise_ki(arg):
        PyErr_SetNone(PyExc)
        return 0
    box_a['ready'].set()
    g = {}
    try:
        exec(WORK_CODE, g)
        case_a['r'] = g['__r__']
    except BaseException as e:
        case_a['r'] = 'worker-crashed:' + repr(e)
    time.sleep(3.2)  # 等 sniper 提交后再进下一轮（避免 case 串扰）
    rc = AddPending(raise_ki, None)
    print(f'[A-sniper2] rc={rc} (验证队列仍可提交)', flush=True)

def case_a_sniper():
    time.sleep(1.5)
    # pending 由 worker 内 sniper2 在自身线程提交——不行，A 要模拟外部线程提交：
    pass

WORK_CODE = (
    'import time\n'
    'try:\n'
    '    for i in range(20):\n'
    '        __tick__ = i\n'
    '        time.sleep(0.5)\n'
    '    __r__ = "ran-full"\n'
    'except BaseException as e:\n'
    '    __r__ = "interrupted:" + type(e).__name__ + "@tick" + str(__tick__)\n'
)

def run_case(name, submit_fn, expect_window):
    result = {}
    box = {'ready': threading.Event()}
    def worker():
        box['ptr'] = GetThisThreadState()
        box['ready'].set()
        g = {}
        try:
            exec(WORK_CODE, g)
            result['r'] = g['__r__']
        except BaseException as e:
            result['r'] = 'worker-crashed:' + repr(e)
    def sniper():
        time.sleep(1.5)
        try:
            submit_fn(box)
        except BaseException as e:
            print(f'[{name}-sniper] raised {e!r}', flush=True)
    w = threading.Thread(target=worker); s = threading.Thread(target=sniper)
    t0 = time.time()
    w.start(); s.start()
    w.join(timeout=20); s.join(timeout=1)
    elapsed = time.time() - t0
    ok = result.get('r', '').startswith('interrupted')
    print(f'[{name}] elapsed={elapsed:.1f}s result={result.get("r")!r} => {"生效" if ok else "未生效"}', flush=True)

# 通道 A：外部线程 Py_AddPendingCall（不持 GIL——CDLL 调用自动放 GIL）
def submit_pending(box):
    AddPending = cdll.Py_AddPendingCall
    AddPending.restype = ctypes.c_int
    AddPending.argtypes = [ctypes.c_void_p, ctypes.c_void_p]
    PyExc = ctypes.c_void_p.in_dll(cdll, 'PyExc_KeyboardInterrupt')
    PyErr_SetNone = cdll.PyErr_SetNone
    PyErr_SetNone.restype = None
    PyErr_SetNone.argtypes = [ctypes.c_void_p]
    @ctypes.PYFUNCTYPE(ctypes.c_int, ctypes.c_void_p)
    def raise_ki(arg):
        PyErr_SetNone(PyExc)
        return 0
    rc = AddPending(raise_ki, None)
    print(f'[A-sniper] rc={rc}', flush=True)

# 通道 B：外部线程持 GIL 调 SetAsyncExc（PyDLL 调用保持 GIL）
def submit_async_exc(box):
    SetAsyncExc = pydll.PyThreadState_SetAsyncExc
    SetAsyncExc.restype = ctypes.c_int
    SetAsyncExc.argtypes = [ctypes.c_void_p, ctypes.py_object]
    rc = SetAsyncExc(box['ptr'], KeyboardInterrupt)
    print(f'[B-sniper] rc={rc}', flush=True)

run_case('A-pending-call', submit_pending, None)
time.sleep(0.5)
run_case('B-set-async-exc', submit_async_exc, None)
print('DIAG-DONE', flush=True)
