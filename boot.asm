; ==========================================
; Bootloader (Sector 0)
; 加载地址: 3072 (0x0C00)
; 空闲地址: 3584 (0x0E00)
; ==========================================

MAIN:
    ; 打印 Bootloader Starting...
    LIT 0
    LIT '\n'
    LIT '.'
    LIT '.'
    LIT '.'
    LIT 'g'
    LIT 'n'
    LIT 'i'
    LIT 't'
    LIT 'r'
    LIT 'a'
    LIT 't'
    LIT 'S'
    LIT ' '
    LIT 'r'
    LIT 'e'
    LIT 'd'
    LIT 'a'
    LIT 'o'
    LIT 'l'
    LIT 't'
    LIT 'o'
    LIT 'o'
    LIT 'B'
    CALL PUT_STR

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
    LIT 0x0E04
    LOAD
    LIT 0x0E00
    LOAD
    
    CALL READ_DISK_WRAPPER

    ; Address += 512
    LIT 0x0E04
    LOAD
    LIT 512
    ADDI
    LIT 0x0E04
    STORE

    ; Sector += 1
    LIT 0x0E00
    LOAD
    LIT 1
    ADDI
    LIT 0x0E00
    STORE

    ; Sector <= Count
    LIT 0x0E00
    LOAD
    LIT 0x0E08
    LOAD
    LEI
    NBZ LOOP

    ; 跳转到内核
    JMP 4096

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

; --- 读盘包装函数 ---
READ_DISK_WRAPPER:
    LIT DISK_SECTOR_0
    STORE          ; 填扇区 (Stack: Address)

    LIT DISK_ADDR_0
    STORE          ; 填地址 (Stack: Empty)

    LIT 1
    LIT DISK_CMD
    STORE_B        ; 触发读取

    RET