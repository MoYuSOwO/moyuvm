; ==========================================
; MoYuOS Kernel
; 加载地址: 4096 (0x1000)
; ==========================================

OS_ENTRY:
    ; 打印欢迎语 ">>> Welcome to MoYuOS 1.0"
    LIT 0
    LIT '\n'
    LIT '0'
    LIT '.'
    LIT '1'
    LIT ' '
    LIT 'S'
    LIT 'O'
    LIT 'u'
    LIT 'Y'
    LIT 'o'
    LIT 'M'
    LIT ' '
    LIT 'o'
    LIT 't'
    LIT ' '
    LIT 'e'
    LIT 'm'
    LIT 'o'
    LIT 'c'
    LIT 'l'
    LIT 'e'
    LIT 'W'
    LIT ' '
    LIT '>'
    LIT '>'
    LIT '>'
    CALL PUT_STR

    CALL MEM_INIT

    DBG

    LIT 1024
    CALL MALLOC

    DBG

    LIT 256
    CALL MALLOC

    DBG

    
IDLE:
    JMP IDLE

; --- 打印包装函数 ---
PUT_STR:
    DUP
    LIT 0
    EQI
    BZ _STR
    DROP
    RET

_STR:
    LIT SERIAL_DATA
    STORE_B
    JMP PUT_STR

; ==========================================================
; 内存管理单元 (Memory Manager)
; 基于 Bitmap + PageInfo 的连续物理页分配器
; ==========================================================

; --- 全局变量地址定义 ---
; Bitmap: 0x0400 (32字节)
; PageInfo: 0x0500 (256字节)
; 变量区: 0x0600
; [临时] 想要申请的页数: 0x0600
; [临时] 当前搜索到的页号: 0x0604
; [临时] 连续找到的空闲页数: 0x0608
; [临时] 清空Bitmap: 0x0610



; ==========================================================
; 1. MEM_INIT
; 功能：初始化内存管理器，把系统区标记为占用
; ==========================================================
MEM_INIT:
    ; 1. 清空Bitmap (32字节置0)
    CALL CLEAR_BITMAP_ENTRY
    
    ; 2. 标记系统保留区 (0x0000 ~ 0x2FFF，6个字节)
    LIT 0xFF
    LIT 0x0400
    STORE_B
    
    LIT 0xFF
    LIT 0x0401
    STORE_B
    
    LIT 0xFF
    LIT 0x0402
    STORE_B
    
    LIT 0xFF
    LIT 0x0403
    STORE_B
    
    LIT 0xFF
    LIT 0x0404
    STORE_B
    
    LIT 0xFF
    LIT 0x0405
    STORE_B
    
    RET

CLEAR_BITMAP_ENTRY:
    ; 赋初始值
    LIT 32
    LIT 0x0610
    STORE
    JMP _CLEAR_BITMAP_LOOP

_CLEAR_BITMAP_RET:
    RET

_CLEAR_BITMAP_LOOP:
    ; 循环条件判断
    LIT 0x0610
    LOAD
    BZ _CLEAR_BITMAP_RET

    ; 为偏移地址赋值0
    LIT 0
    LIT 0x0400
    LIT 0x0610
    LOAD
    ADDI
    LIT 1
    SUBI
    STORE_B

    ; 自减
    LIT 0x0610
    LOAD
    LIT 1
    SUBI
    LIT 0x0610
    STORE

    JMP _CLEAR_BITMAP_LOOP

; ==========================================================
; 2. MALLOC
; 参数：栈顶 = 申请字节数 (Size)
; 返回：栈顶 = 内存地址 (失败返回 0)
; ==========================================================
MALLOC:
    ; 计算需要的页数 (/256 == >>8)
    LIT 255
    ADDI
    LIT 8
    SHR
    
    ; 如果申请0页，直接返回0
    DUP
    BZ MALLOC_FAIL_POP

    ; 保存到临时变量
    DUP
    LIT 0x0600
    STORE       ; 存起来，栈里留一份备份

    ; 开始搜索Bitmap，从第0页开始找
    LIT 0
    LIT 0x0604
    STORE

MALLOC_SEARCH_LOOP:
    LIT 0
    LIT 0x0608
    STORE
    
MALLOC_CHECK_CONSECUTIVE:
    ; 获取当前要检查的页号
    LIT 0x0604
    LOAD
    LIT 0x0608
    LOAD
    ADDI

    ; 越界检查
    DUP
    LIT 256
    GEI
    NBZ MALLOC_FAIL

    ; 检查这个页的状态
    CALL GET_BIT
    ; 结果在栈顶：1(占用), 0(空闲)
    NBZ MALLOC_BIT_OCCUPIED

MALLOC_BIT_FREE:
    LIT 0x0608
    LOAD
    LIT 1
    ADDI
    LIT 0x0608
    STORE

    ; 检查是否找够了？
    LIT 0x0608
    LOAD
    LIT 0x0600
    LOAD
    EQI
    NBZ MALLOC_SUCCESS ; 找够了！去分配

    ; 没找够，继续检查下一位
    JMP MALLOC_CHECK_CONSECUTIVE

MALLOC_BIT_OCCUPIED:
    ; 被占用了！之前积累的连续计数清零，跳到这个被占用位的下一位重新开始
    LIT 0x0604
    LOAD
    LIT 0x0608
    LOAD
    ADDI
    LIT 1
    ADDI
    
    LIT 0x0604
    STORE
    
    JMP MALLOC_SEARCH_LOOP

MALLOC_SUCCESS:
    ; 找到了！标记Bitmap并记录PageInfo
    LIT 0x0600
    LOAD        ; Value: Page Count
    
    LIT 0x0500  ; Base Addr
    LIT 0x0604
    LOAD        ; Offset
    ADDI        ; Target Addr
    
    STORE_B     ; Write PageInfo

    ; 标记 Bitmap (循环 Set Bit)
    ; 利用 0x0608 作为倒计时
MALLOC_MARK_LOOP:
    ; Check Count == 0 ?
    LIT 0x0608
    LOAD
    LIT 0
    EQI
    NBZ MALLOC_DONE

    ; Set Bit = 1
    ; Page = Search_Idx + Found_Count - 1
    LIT 1       ; Val = 1
    
    LIT 0x0604
    LOAD
    LIT 0x0608
    LOAD
    ADDI
    LIT 1
    SUBI        ; Page Index
    
    CALL SET_BIT

    ; Count--
    LIT 0x0608
    LOAD
    LIT 1
    SUBI
    LIT 0x0608
    STORE
    
    JMP MALLOC_MARK_LOOP

MALLOC_DONE:
    ; 返回地址 = Start_Page * 256
    ; 清理掉栈顶那个备份的 Size
    DROP 
    
    LIT 0x0604
    LOAD
    LIT 8
    SHL         ; Page * 256
    RET

MALLOC_FAIL:
    ; 失败，返回 0
    ; 清理栈
    DROP ; Drop 备份的 Size
    DROP ; Drop Check_Page
    LIT 0
    RET

MALLOC_FAIL_POP:
    DROP
    LIT 0
    RET

; ==========================================================
; 辅助函数：GET_BIT
; 参数：栈顶 = Page_Index
; 返回：栈顶 = 0 或 1
; ==========================================================
GET_BIT:
    ; Byte_Addr = 0x0400 + (Page >> 3)
    DUP
    LIT 3
    SHR
    LIT 0x0400
    ADDI        ; [Page, Byte_Addr]

    ; Bit_Offset = Page & 7
    SWAP        ; [Byte_Addr, Page]
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
    RET

; ==========================================================
; 辅助函数：SET_BIT
; 参数：栈顶 = Page_Index, 次栈顶 = Value (0 or 1)
; ==========================================================
SET_BIT:
    ; Stack: [Val, Page]
    
    ; 1. 计算 Byte_Addr 和 Bit_Offset
    DUP         ; [Val, Page, Page]
    LIT 3
    SHR
    LIT 0x0400
    ADDI        ; [Val, Page, Byte_Addr]
    
    SWAP        ; [Val, Byte_Addr, Page]
    LIT 7
    AND         ; [Val, Byte_Addr, Bit_Offset]
    
    ; 2. 读出原来的 Byte
    PICK 1      ; [Val, Byte_Addr, Bit_Offset, Byte_Addr]
    LOAD_B      ; [Val, Byte_Addr, Bit_Offset, Old_Byte]
    
    ; 3. 根据 Val 是 0 还是 1 分支
    PICK 3      ; Pick Val
    LIT 0
    EQI
    NBZ SET_BIT_CLEAR

SET_BIT_SET:
    ; Old_Byte | (1 << Offset)
    LIT 1
    PICK 2      ; Pick Offset
    SHL         ; 1 << Offset
    OR          ; Old | Mask
    JMP SET_BIT_WRITE

SET_BIT_CLEAR:
    ; Old_Byte & ~(1 << Offset)
    LIT 1
    PICK 2      ; Pick Offset
    SHL         ; 1 << Offset
    NOT         ; ~(Mask)
    AND         ; Old & ~Mask

SET_BIT_WRITE:
    ; Stack: [Val, Byte_Addr, Bit_Offset, New_Byte]
    ; 写入
    PICK 2      ; Pick Byte_Addr
    STORE_B     ; Memory[Byte_Addr] = New_Byte
    
    ; 清理栈 [Val, Byte_Addr, Bit_Offset]
    DROP
    DROP
    DROP
    RET