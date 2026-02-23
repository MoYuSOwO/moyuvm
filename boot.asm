; ==========================================
; Bootloader (Sector 0)
; 加载地址: 3072 (0x0C00)
; 空闲地址: 3584 (0x0E00)
; ==========================================

; 常量定义
CONST VAR_SECTOR    0x0E00
CONST VAR_ADDR      0x0E04
CONST VAR_COUNT     0x0E08
CONST KERNEL_ADDR   4096

; MMIO 常量
CONST SERIAL_DATA   0x100002
CONST DISK_ADDR_0   0x100010
CONST DISK_SECTOR_0 0x100014
CONST DISK_CMD      0x100018

MAIN:
    STF

    ; 打印 Bootloader Starting...
    LIT msg_start
    CALL PRINT_STR
    DROP

    ; 初始化变量
    LIT 1
    LIT 0x0E00
    STORE       ; Sector = 1

    LIT 4096
    LIT 0x0E04
    STORE       ; Address = 4096 (Kernel Entry)

    LIT 10
    LIT 0x0E08
    STORE       ; Count = 10 (读10个扇区)

LOOP:
    ; 准备参数
    LIT VAR_ADDR
    LOAD
    LIT VAR_SECTOR
    LOAD
    
    CALL READ_DISK_WRAPPER

    DROP
    DROP

    ; Address += 512
    LIT VAR_ADDR
    LOAD
    LIT 512
    ADDI
    LIT VAR_ADDR
    STORE

    ; Sector += 1
    LIT VAR_SECTOR
    LOAD
    LIT 1
    ADDI
    LIT VAR_SECTOR
    STORE

    ; Sector <= Count ?
    LIT VAR_SECTOR
    LOAD
    LIT VAR_COUNT
    LOAD
    LEI
    NBZ LOOP

    ; 跳转到内核
    LIT msg_done
    CALL PRINT_STR
    DROP
    JMP 4096
    HLT

; --- 读盘包装函数 ---
READ_DISK_WRAPPER:
    GR FP
    STF

    PEF 8
    LIT DISK_SECTOR_0
    STORE          ; 填扇区 (Stack: Address)

    PEF 12
    LIT DISK_ADDR_0
    STORE          ; 填地址 (Stack: Empty)

    LIT 1
    LIT DISK_CMD
    STORE_B        ; 触发读取

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

; 数据区
msg_start:
    STRING "Bootloader Starting...\n"

msg_done:
    STRING "Boot complete. Jumping to Kernel...\n"