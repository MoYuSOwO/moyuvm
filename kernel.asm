; ==========================================
; MoYuOS Kernel 1.0
; 加载地址: 4096 (0x1000)
; ==========================================

; 内存映射常量
CONST SERIAL_DATA       0x100002
CONST BITMAP_BASE       0x0800
CONST PAGE_INFO_BASE    0x0900

; 内存管理器临时变量区
CONST VAR_MALLOC_SIZE   0x0A00
CONST VAR_SEARCH_IDX    0x0A04
CONST VAR_FOUND_COUNT   0x0A08
CONST VAR_CLEAR_COUNT   0x0A10

CONST VAR_FREE_PAGE_IDX 0x0A14
CONST VAR_FREE_COUNT    0x0A18

CONST VAR_FREE_PAGES    0x0A1C

OS_ENTRY:
    STF

    LIT msg_welcome
    CALL PRINT_STR
    DROP

    CALL MEM_INIT

TEST:
    LIT 1024
    CALL MALLOC
    DROP
    GR RV        ; 预期: 0x3000 (占用了 3000~33FF)

    DBG

    LIT 256
    CALL MALLOC
    DROP
    GR RV        ; 预期: 0x3400 (占用了 3400~34FF)

    DBG

    ; 现在释放中间那块！
    LIT 0x3000
    CALL FREE
    DROP         ; 现在 3000~33FF 空了，但 3400 还占着

    LIT 512
    CALL MALLOC
    DROP
    GR RV        ; 预期: 0x3000 (能填进刚才 1024 字节留下的坑！)

    DBG

    LIT 1024
    CALL MALLOC
    DROP
    GR RV        ; 预期: 0x3500 (前面的坑不够 1024 了，只能往后找！)

    DBG

    LIT VAR_FREE_PAGES
    LOAD

    DBG

    
IDLE:
    JMP IDLE


; 内存管理单元

; MEM_INIT 初始化内存管理器，把系统区标记为占用
MEM_INIT:
    GR FP
    STF

    ; 清空Bitmap (32字节置0)
    LIT 32
    LIT VAR_CLEAR_COUNT
    STORE

_CLEAR_BITMAP_LOOP:
    LIT VAR_CLEAR_COUNT
    LOAD
    BZ _CLEAR_BITMAP_RET
    
    ; Memory[BITMAP_BASE + COUNT - 1] = 0
    LIT 0
    LIT BITMAP_BASE
    LIT VAR_CLEAR_COUNT
    LOAD
    ADDI
    LIT 1
    SUBI
    STORE_B

    ; Count--
    LIT VAR_CLEAR_COUNT
    LOAD
    LIT 1
    SUBI
    LIT VAR_CLEAR_COUNT
    STORE
    JMP _CLEAR_BITMAP_LOOP

_CLEAR_BITMAP_RET:
    ; 标记系统保留区 (0x0000 ~ 0x2FFF，占用前6个字节的Bitmap)
    ; 即前 48 页 (48 * 256 = 12288 = 0x3000)
    LIT 0xFF
    LIT 0x0800
    STORE_B
    LIT 0xFF
    LIT 0x0801
    STORE_B
    LIT 0xFF
    LIT 0x0802
    STORE_B
    LIT 0xFF
    LIT 0x0803
    STORE_B
    LIT 0xFF
    LIT 0x0804
    STORE_B
    LIT 0xFF
    LIT 0x0805
    STORE_B

    ; 初始化内存计数器
    LIT 208
    LIT VAR_FREE_PAGES
    STORE

    SR FP

    RET

; ==========================================================
; 2. MALLOC
; 参数：栈顶 = 申请字节数 (Size)
; 返回：栈顶 = 内存地址 (失败返回 0)
; ==========================================================
MALLOC:
    GR FP
    STF

    ; 绝对物理上限防溢出
    PEF 8
    LIT 65536
    GEI             ; Size >= 65536 ?
    NBZ _MALLOC_FAIL

    ; 计算需要的页数 (/256 == >>8)
    PEF 8
    LIT 255
    ADDI
    LIT 8
    SHR
    
    ; 如果申请0页，直接返回0
    DUP
    BZ _MALLOC_FAIL_CLEAN_1

    ; 剩余总量拦截
    DUP
    LIT VAR_FREE_PAGES
    LOAD
    GTI             ; PageCount > FreePages ?
    NBZ _MALLOC_FAIL_CLEAN_1

    ; 保存到临时变量
    LIT VAR_MALLOC_SIZE
    STORE

    ; 开始搜索Bitmap，从第0页开始找
    LIT 0
    LIT VAR_SEARCH_IDX
    STORE

_MALLOC_SEARCH_LOOP:
    LIT 0
    LIT VAR_FOUND_COUNT
    STORE
    
_MALLOC_CHECK_CONSECUTIVE:
    ; 当前检查页 = SearchIdx + FoundCount
    LIT VAR_SEARCH_IDX
    LOAD
    LIT VAR_FOUND_COUNT
    LOAD
    ADDI

    ; 越界检查
    DUP
    LIT 256
    GEI
    NBZ _MALLOC_FAIL_CLEAN_1

    ; 检查这个页的状态
    CALL GET_BIT
    DROP
    GR RV
    ; 结果在栈顶：1(占用), 0(空闲)
    NBZ _MALLOC_BIT_OCCUPIED

_MALLOC_BIT_FREE:
    LIT VAR_FOUND_COUNT
    LOAD
    LIT 1
    ADDI
    LIT VAR_FOUND_COUNT
    STORE

    ; 检查是否找够了
    LIT VAR_FOUND_COUNT
    LOAD
    LIT VAR_MALLOC_SIZE
    LOAD
    EQI
    NBZ _MALLOC_SUCCESS ; 找够了！去分配
    JMP _MALLOC_CHECK_CONSECUTIVE ; 没找够，继续检查下一位

_MALLOC_BIT_OCCUPIED:
    ; 被占用了！之前积累的连续计数清零，跳到这个被占用位的下一位重新开始
    LIT VAR_SEARCH_IDX
    LOAD
    LIT VAR_FOUND_COUNT
    LOAD
    ADDI
    LIT 1
    ADDI
    
    LIT VAR_SEARCH_IDX
    STORE
    
    JMP _MALLOC_SEARCH_LOOP

_MALLOC_SUCCESS:
    ; 找到了！标记Bitmap并记录PageInfo
    LIT VAR_MALLOC_SIZE
    LOAD        ; Value: Page Count
    
    LIT PAGE_INFO_BASE  ; Base Addr
    LIT VAR_SEARCH_IDX
    LOAD        ; Offset
    ADDI        ; Target Addr
    
    STORE_B     ; Write PageInfo

; 标记 Bitmap
_MALLOC_MARK_LOOP:
    ; Check Count == 0 ?
    LIT VAR_FOUND_COUNT
    LOAD
    LIT 0
    EQI
    NBZ _MALLOC_DONE

    ; Set Bit = 1
    ; Page = Search_Idx + Found_Count - 1
    LIT 1       ; Val = 1
    
    LIT VAR_SEARCH_IDX
    LOAD
    LIT VAR_FOUND_COUNT
    LOAD
    ADDI
    LIT 1
    SUBI        ; Page Index
    
    CALL SET_BIT

    DROP
    DROP

    ; Count--
    LIT VAR_FOUND_COUNT
    LOAD
    LIT 1
    SUBI
    LIT VAR_FOUND_COUNT
    STORE
    
    JMP _MALLOC_MARK_LOOP

_MALLOC_DONE:
    ; 扣除剩余内存: FreePages = FreePages - MallocSize
    LIT VAR_FREE_PAGES
    LOAD
    LIT VAR_MALLOC_SIZE
    LOAD
    SUBI
    LIT VAR_FREE_PAGES
    STORE

    LIT VAR_SEARCH_IDX
    LOAD
    LIT 8
    SHL         ; Page * 256

    SR RV

    SR FP
    RET

_MALLOC_FAIL_CLEAN_1:
    DROP
_MALLOC_FAIL:
    LIT 0
    SR RV
    SR FP
    RET

; ==========================================================
; FREE
; 参数：栈顶 = 内存地址 (Address)
; 返回：无
; ==========================================================
FREE:
    GR FP
    STF

    ; 地址转为 Page_Index (Address >> 8)
    PEF 8
    LIT 8
    SHR
    
    ; 存入临时变量
    LIT VAR_FREE_PAGE_IDX
    STORE

    ; 查表获取分配的页数 (Page_Count)
    LIT PAGE_INFO_BASE
    LIT VAR_FREE_PAGE_IDX
    LOAD
    ADDI
    LOAD_B      ; 读取那一页记录的 Count

    ; 检查 Count 是否为 0 (防止 Double Free 或释放野指针)
    DUP
    BZ _FREE_END_CLEAN  ; 如果是 0，直接结束

    ; 存入临时变量
    LIT VAR_FREE_COUNT
    STORE

    ; 清除 PAGE_INFO 记录 (防患于未然)
    LIT 0
    LIT PAGE_INFO_BASE
    LIT VAR_FREE_PAGE_IDX
    LOAD
    ADDI
    STORE_B

    LIT VAR_FREE_PAGES
    LOAD
    LIT VAR_FREE_COUNT
    LOAD
    ADDI
    LIT VAR_FREE_PAGES
    STORE

; 循环清除 Bitmap
_FREE_LOOP:
    LIT VAR_FREE_COUNT
    LOAD
    BZ _FREE_END

    ; 准备调用 SET_BIT (Value=0, Page_Index)
    ; 注意压栈顺序：[Value, Page_Index]
    LIT 0       ; Value = 0
    
    LIT VAR_FREE_PAGE_IDX
    LOAD
    LIT VAR_FREE_COUNT
    LOAD
    ADDI
    LIT 1
    SUBI        ; 计算当前的 Page Index

    CALL SET_BIT
    DROP
    DROP        ; 调用者清理两个参数

    ; Count--
    LIT VAR_FREE_COUNT
    LOAD
    LIT 1
    SUBI
    LIT VAR_FREE_COUNT
    STORE

    JMP _FREE_LOOP

_FREE_END_CLEAN:
    DROP

_FREE_END:
    SR FP
    RET

; ==========================================================
; 辅助函数：GET_BIT
; 参数：栈顶 = Page_Index
; 返回：栈顶 = 0 或 1
; ==========================================================
GET_BIT:
    GR FP
    STF

    ; Byte_Addr = 0x0400 + (Page >> 3)
    PEF 8
    LIT 3
    SHR
    LIT BITMAP_BASE
    ADDI        ; [Byte_Addr]

    ; Bit_Offset = Page & 7
    PEF 8
    LIT 7
    AND         ; [Byte_Addr, Bit_Offset]

    ; Load Byte
    SWAP        ; [Bit_Offset, Byte_Addr]
    LOAD_B      ; [Bit_Offset, Byte_Val]
    
    ; Extract Bit: (Val >> Offset) & 1
    SWAP        ; [Byte_Val, Bit_Offset]
    SHR
    LIT 1
    AND

    SR RV

    SR FP
    RET

; ==========================================================
; 辅助函数：SET_BIT
; 参数：栈顶 = Page_Index, 次栈顶 = Value (0 or 1)
; ==========================================================
SET_BIT:
    GR FP
    STF

    ; PEF 8 -> Page_Index，PEF 12 -> Value
    
    ; 计算 Byte_Addr
    PEF 8
    LIT 3
    SHR
    LIT BITMAP_BASE
    ADDI        ; [Byte_Addr]

    ; 计算 Bit_Offset
    PEF 8
    LIT 7
    AND         ; [Byte_Addr, Bit_Offset]
    
    ; 读出原来的 Byte
    PES 4       ; [Byte_Addr, Bit_Offset, Byte_Addr]
    LOAD_B      ; [Byte_Addr, Bit_Offset, Old_Byte]
    
    ; 分支：Set 还是 Clear
    PEF 12      ; P ick Val
    BZ _SET_BIT_CLEAR

_SET_BIT_SET:
    ; Old_Byte | (1 << Offset)
    LIT 1
    PES 8       ; Pick Offset
    SHL         ; 1 << Offset
    OR          ; Old | Mask
    JMP _SET_BIT_WRITE

_SET_BIT_CLEAR:
    ; Old_Byte & ~(1 << Offset)
    LIT 1
    PES 8       ; Pick Offset
    SHL         ; 1 << Offset
    NOT         ; ~(Mask)
    AND         ; Old & ~Mask

_SET_BIT_WRITE:
    ; Stack: [Byte_Addr, Bit_Offset, New_Byte]
    ; 写入
    PES 8       ; Pick Byte_Addr
    STORE_B     ; Memory[Byte_Addr] = New_Byte
    
    ; 清理栈 [Byte_Addr, Bit_Offset]
    DROP
    DROP
    SR FP
    RET

; 字符串打印函数
PRINT_STR:
    GR FP
    STF

    PEF 8             ; [Addr]


PRINT_LOOP:
    DUP               ; [Addr, Addr]
    LOAD_B            ; [Addr, Char]
    DUP               ; [Addr, Char, Char]
    BZ PRINT_END      ; 如果 Char == 0，跳转到结束

    ; 打印字符
    LIT SERIAL_DATA   ; [Addr, Char, SERIAL_DATA]
    STORE_B

    ; 地址 + 1，继续循环
    LIT 1
    ADDI
    JMP PRINT_LOOP

PRINT_END:
    ; 清理栈上的残留物 [Addr, 0]
    DROP
    DROP

    SR FP

    RET

msg_welcome:
    STRING ">>> Welcome to MoYuOS 1.0\n"