#include <stdio.h>
#include <stdint.h>
#include <stdbool.h>
#include <stdlib.h>
#include <conio.h>

#define STACK_SIZE 256
#define RETURN_STACK_SIZE 256
#define MEM_SIZE 65536

#define VIT_SIZE 1024
#define BOOTLOADER_ENTRY 3072
#define OS_ENTRY 4096

#define MMIO_BASE 0x100000
#define MMIO_SERIAL_IO_STATUS 0x100001
#define MMIO_SERIAL_IO 0x100002
 
// 存目标内存地址
#define MMIO_DISK_ADDR_0 0x100010
#define MMIO_DISK_ADDR_1 0x100011
#define MMIO_DISK_ADDR_2 0x100012
#define MMIO_DISK_ADDR_3 0x100013
// 存扇区号
#define MMIO_DISK_SECTOR_0 0x100014
#define MMIO_DISK_SECTOR_1 0x100015 
#define MMIO_DISK_SECTOR_2 0x100016 
#define MMIO_DISK_SECTOR_3 0x100017 
// 命令寄存器 (写这个触发动作)
#define MMIO_DISK_CMD 0x100018
#define MMIO_POWER_OFF 0x100020

#define KEYBORD_INT_ID 1
#define KEYBORD_INT_START 1025
#define DEFAULT_INT_START 1024

typedef union {
    uint32_t u;
    int32_t i;
    float f;
} BitCaster;

typedef struct {
    uint32_t pc;
    uint32_t sp;
    uint32_t stack[STACK_SIZE];
    uint32_t rsp;
    uint32_t rstack[RETURN_STACK_SIZE];
    uint8_t memory[MEM_SIZE]; 
    bool running;
    bool halted;
    bool int_enable;
    bool int_pending;
    uint32_t int_vector;
    uint32_t base_offset;
} VM;

typedef struct {
    uint8_t data;
    uint8_t status;
} IO;

typedef struct {
    uint8_t addr[4];
    uint8_t sector[4];
    FILE *disk;
} FIO;

VM vm;
IO io;
FIO fio;

typedef enum {
    // 基础操作
    HLT = 0x00, 
    LIT, // 压入立即数n (带操作数n)
    
    // 内存操作
    LOAD = 0x10, // 读32bit内存 (地址在栈顶)
    STORE, // 写32bit内存 (地址在栈顶，值在次顶)
    LOAD_B, // 读8bit内存 (高位补0变成32位压栈)
    STORE_B, // 写8bit内存 (只写低8位)

    // 栈操作
    DUP = 0x20, // 复制栈顶
    SWAP, // 交换两个栈顶元素
    DROP, // 丢弃栈顶元素
    PICK, // 偷窥栈下面的第n个元素 (带操作数n)

    // 整数运算
    ADDI = 0x30, SUBI, MULI, DIVI, MOD, ITF,

    // 浮点运算
    ADDF = 0x40, SUBF, MULF, DIVF, FTI, 
    
    // 逻辑运算
    AND = 0x50, OR, XOR, NOT, SHL, SHR,
    
    // 整数比较 (结果1或0入栈)
    EQI = 0x60, NEQI, LTI, GTI, LEI, GEI,

    // 浮点比较
    EQF = 0x70, NEQF, LTF, GTF, LEF, GEF,

    // 跳转
    JMP = 0x80, // 无条件跳转到地址n (带操作数n)
    IJMP, // 动态跳
    BZ, // 栈顶为0则跳转到地址n (带操作数n)
    NBZ, // 栈顶非0则跳转到地址n (带操作数n)
    CALL, // 函数调用，将当前PC压入返回栈然后跳转到地址n (带操作数n)
    RET, // 函数返回，从返回栈弹出一个地址，赋值给PC
    IRET, // 中断返回

    // 原子性
    CLI = 0x90, // 进入原子区
    STI, // 退出原子区
    INT, // 软中断
    SBS, // 设定基址
    
    // 调试用
    DBG = 0xFF  // 打印整个栈
} OpCode;

uint32_t resolve_addr(uint32_t logic_addr) {
    if (logic_addr >= MMIO_BASE) {
        return logic_addr;
    }
    uint32_t phys_addr = logic_addr + vm.base_offset;
    if (phys_addr >= MEM_SIZE || phys_addr < logic_addr) {
        error("Segmentation Fault");
    }
    
    return phys_addr;
}

void error(const char* msg) {
    printf("Panic: %s\n", msg);
    vm.running = false;
    exit(1);
}

void push(uint32_t val) {
    if (vm.sp >= STACK_SIZE) error("Stack Overflow");
    vm.stack[vm.sp++] = val;
}

uint32_t pop() {
    if (vm.sp == 0) error("Stack Underflow");
    return vm.stack[--vm.sp];
}

uint32_t top() {
    if (vm.sp == 0) error("Stack Underflow");
    if (vm.sp > STACK_SIZE) error("Stack Overflow");
    return vm.stack[vm.sp - 1];
}

uint32_t peak_at(uint32_t soffset) {
    uint32_t tsp = vm.sp - soffset - 1;
    if (tsp >= STACK_SIZE) error("Stack Overflow");
    return vm.stack[tsp];
}

void rpush(uint32_t val) {
    if (vm.rsp >= RETURN_STACK_SIZE) error("Return Stack Overflow");
    vm.rstack[vm.rsp++] = val;
}

uint32_t rpop() {
    if (vm.rsp == 0) error("Return Stack Underflow");
    return vm.rstack[--vm.rsp];
}

// 总线读取
uint8_t bus_read(uint32_t addr) {
    uint32_t phys_addr = resolve_addr(addr);
    if (phys_addr == MMIO_SERIAL_IO_STATUS) {
        return io.status;
    } else if (phys_addr == MMIO_SERIAL_IO) {
        io.status = 0;
        return io.data;
    } else if (phys_addr >= MMIO_DISK_ADDR_0 && phys_addr <= MMIO_DISK_ADDR_3) {
        return fio.addr[phys_addr - MMIO_DISK_ADDR_0];
    } else if (phys_addr >= MMIO_DISK_SECTOR_0 && phys_addr <= MMIO_DISK_SECTOR_3) {
        return fio.sector[phys_addr - MMIO_DISK_SECTOR_0];
    } 
    return vm.memory[phys_addr];
}

// 取32位立即数
uint32_t fetch_u32() {
    uint32_t val = 0;
    val |= (uint32_t)bus_read(vm.pc++) << 24;
    val |= (uint32_t)bus_read(vm.pc++) << 16;
    val |= (uint32_t)bus_read(vm.pc++) << 8;
    val |= (uint32_t)bus_read(vm.pc++);
    return val;
}

// load 32位数
uint32_t load_u32(uint32_t addr) {
    uint32_t val = 0;
    val |= (uint32_t)bus_read(addr) << 24;
    val |= (uint32_t)bus_read(addr + 1) << 16;
    val |= (uint32_t)bus_read(addr + 2) << 8;
    val |= (uint32_t)bus_read(addr + 3);
    return val;
}

void hardware_disk_exec(int cmd) {
    if (!fio.disk) return;
    
    // 移动磁头
    FILE* disk = fio.disk;
    uint32_t addr = load_u32(MMIO_DISK_ADDR_0);
    uint32_t sector = load_u32(MMIO_DISK_SECTOR_0);
    long offset = sector * 512;
    fseek(disk, offset, SEEK_SET);

    // 数据搬运
    if (cmd == 1) {
        if (addr + 512 <= MEM_SIZE) {
            fread(&vm.memory[addr], 1, 512, disk);
        }
    } else if (cmd == 2) {
        if (addr + 512 <= MEM_SIZE) {
            fwrite(&vm.memory[addr], 1, 512, disk);
        }
    }
}

// 总线写入
void bus_write(uint32_t addr, uint8_t val) {
    uint32_t phys_addr = resolve_addr(addr);
    if (phys_addr == MMIO_SERIAL_IO) {
        putchar((char)val);
        fflush(stdout);
        return;
    } else if (phys_addr >= MMIO_DISK_ADDR_0 && phys_addr <= MMIO_DISK_ADDR_3) {
        fio.addr[phys_addr - MMIO_DISK_ADDR_0] = val;
    } else if (phys_addr >= MMIO_DISK_SECTOR_0 && phys_addr <= MMIO_DISK_SECTOR_3) {
        fio.sector[phys_addr - MMIO_DISK_SECTOR_0] = val;
    } else if (phys_addr == MMIO_DISK_CMD) {
        hardware_disk_exec(val);
    } else if (phys_addr == MMIO_POWER_OFF) {
        if (val == 0) {
            printf("\nSystem Shutdown. Bye!\n");
            vm.running = false;
        }
    }
    else vm.memory[addr] = val;
}

// store 32位数
void store_u32(uint32_t addr, uint32_t val) {
    bus_write(addr, (uint8_t)((val >> 24) & 0xFF));
    bus_write(addr + 1, (uint8_t)((val >> 16) & 0xFF));
    bus_write(addr + 2, (uint8_t)((val >> 8)  & 0xFF));
    bus_write(addr + 3, (uint8_t)(val & 0xFF));
}

void step() {
    uint8_t op = bus_read(vm.pc++);

    switch(op) {
        case HLT: {
            vm.halted = true;
            break;
        }
            
        case LIT: {
            push(fetch_u32());
            break;
        }

        case LOAD: {
            uint32_t addr = pop();
            push(load_u32(addr));
            break;
        }
        
        case STORE: {
            uint32_t addr = pop();
            uint32_t val = pop();
            store_u32(addr, val);
            break;
        }
        
        case LOAD_B: {
            uint32_t addr = pop();
            push((uint32_t)bus_read(addr));
            break;
        }

        case STORE_B: {
            uint32_t addr = pop();
            uint32_t val = pop();
            bus_write(addr, (uint8_t)val);
            break;
        }

        case DUP: {
            push(top());
            break;
        }

        case SWAP: {
            uint32_t top1 = pop();
            uint32_t top2 = pop();
            push(top1);
            push(top2);
            break;
        }

        case DROP: {
            pop();
            break;
        }

        case PICK: {
            uint32_t soffset = fetch_u32();
            uint32_t val = peak_at(soffset);
            push(val);
            break;
        }

        case ADDI: {
            uint32_t back = pop();
            uint32_t front = pop();
            push(front + back);
            break;
        }

        case SUBI: {
            uint32_t back = pop();
            uint32_t front = pop();
            push(front - back);
            break;
        }

        case MULI: {
            uint32_t back = pop();
            uint32_t front = pop();
            push(front * back);
            break;
        }

        case DIVI: {
            uint32_t back = pop();
            uint32_t front = pop();
            push(front / back);
            break;
        }

        case MOD: {
            uint32_t back = pop();
            uint32_t front = pop();
            push(front % back);
            break;
        }

        case ITF: {
            BitCaster caster;
            caster.u = pop();
            caster.f = (float)caster.i;
            push(caster.u);
            break;
        }

        case ADDF: {
            uint32_t raw_back = pop();
            uint32_t raw_front = pop();
            BitCaster caster_back, caster_front, caster_res;
            caster_back.u = raw_back;
            caster_front.u = raw_front;
            caster_res.f = caster_front.f + caster_back.f;
            push(caster_res.u);
            break;
        }

        case SUBF: {
            uint32_t raw_back = pop();
            uint32_t raw_front = pop();
            BitCaster caster_back, caster_front, caster_res;
            caster_back.u = raw_back;
            caster_front.u = raw_front;
            caster_res.f = caster_front.f - caster_back.f;
            push(caster_res.u);
            break;
        }

        case MULF: {
            uint32_t raw_back = pop();
            uint32_t raw_front = pop();
            BitCaster caster_back, caster_front, caster_res;
            caster_back.u = raw_back;
            caster_front.u = raw_front;
            caster_res.f = caster_front.f * caster_back.f;
            push(caster_res.u);
            break;
        }

        case DIVF: {
            uint32_t raw_back = pop();
            uint32_t raw_front = pop();
            BitCaster caster_back, caster_front, caster_res;
            caster_back.u = raw_back;
            caster_front.u = raw_front;
            caster_res.f = caster_front.f / caster_back.f;
            push(caster_res.u);
            break;
        }

        case FTI: {
            BitCaster caster;
            caster.u = pop();
            caster.i = (int32_t)caster.f;
            push(caster.u);
            break;
        }

        case AND: {
            uint32_t back = pop();
            uint32_t front = pop();
            push(front & back);
            break;
        }

        case OR: {
            uint32_t back = pop();
            uint32_t front = pop();
            push(front | back);
            break;
        }

        case XOR: {
            uint32_t back = pop();
            uint32_t front = pop();
            push(front ^ back);
            break;
        }

        case NOT: {
            uint32_t val = pop();
            push(~val);
            break;
        }

        case SHL: {
            uint32_t back = pop();
            uint32_t front = pop();
            push(front << back);
            break;
        }

        case SHR: {
            uint32_t back = pop();
            uint32_t front = pop();
            push(front >> back);
            break;
        }

        case EQI: {
            BitCaster caster_back, caster_front;
            caster_back.u = pop();
            caster_front.u = pop();
            push(caster_front.i == caster_back.i);
            break;
        }

        case NEQI: {
            BitCaster caster_back, caster_front;
            caster_back.u = pop();
            caster_front.u = pop();
            push(caster_front.i != caster_back.i);
            break;
        }

        case LTI: {
            BitCaster caster_back, caster_front;
            caster_back.u = pop();
            caster_front.u = pop();
            push(caster_front.i < caster_back.i);
            break;
        }

        case GTI: {
            BitCaster caster_back, caster_front;
            caster_back.u = pop();
            caster_front.u = pop();
            push(caster_front.i > caster_back.i);
            break;
        }

        case LEI: {
            BitCaster caster_back, caster_front;
            caster_back.u = pop();
            caster_front.u = pop();
            push(caster_front.i <= caster_back.i);
            break;
        }

        case GEI: {
            BitCaster caster_back, caster_front;
            caster_back.u = pop();
            caster_front.u = pop();
            push(caster_front.i >= caster_back.i);
            break;
        }

        case EQF: {
            BitCaster caster_back, caster_front;
            caster_back.u = pop();
            caster_front.u = pop();
            push(caster_front.f == caster_back.f);
            break;
        }

        case NEQF: {
            BitCaster caster_back, caster_front;
            caster_back.u = pop();
            caster_front.u = pop();
            push(caster_front.f != caster_back.f);
            break;
        }

        case LTF: {
            BitCaster caster_back, caster_front;
            caster_back.u = pop();
            caster_front.u = pop();
            push(caster_front.f < caster_back.f);
            break;
        }

        case GTF: {
            BitCaster caster_back, caster_front;
            caster_back.u = pop();
            caster_front.u = pop();
            push(caster_front.f > caster_back.f);
            break;
        }

        case LEF: {
            BitCaster caster_back, caster_front;
            caster_back.u = pop();
            caster_front.u = pop();
            push(caster_front.f <= caster_back.f);
            break;
        }

        case GEF: {
            BitCaster caster_back, caster_front;
            caster_back.u = pop();
            caster_front.u = pop();
            push(caster_front.f >= caster_back.f);
            break;
        }

        case JMP: {
            uint32_t addr = fetch_u32();
            vm.pc = addr;
            break;
        }

        case IJMP: {
            uint32_t addr = pop();
            vm.pc = addr;
            break;
        }

        case BZ: {
            uint32_t addr = fetch_u32();
            if (pop() == 0) vm.pc = addr;
            break;
        }

        case NBZ: {
            uint32_t addr = fetch_u32();
            if (pop() != 0) vm.pc = addr;
            break;
        }

        case CALL: {
            uint32_t addr = fetch_u32();
            rpush(vm.pc);
            vm.pc = addr;
            break;
        }

        case RET: {
            uint32_t addr = rpop();
            vm.pc = addr;
            break;
        }

        case IRET: {
            vm.pc = rpop();
            vm.base_offset = rpop();
            vm.int_enable = true;
            break;
        }

        case CLI: {
            vm.int_enable = false;
            break;
        }

        case STI: {
            vm.int_enable = true;
            break;
        }

        case INT: {
            uint32_t int_id = fetch_u32();
            rpush(vm.base_offset);
            rpush(vm.pc);
            vm.base_offset = 0;
            uint32_t vector_addr = int_id * 4;
            uint32_t handler_addr = load_u32(vector_addr); 
            vm.pc = handler_addr;
            break;
        }

        case SBS: {
            uint32_t new_base = pop();
            vm.base_offset = new_base;
            vm.pc = 0;
            break;
        }

        case DBG: {
            printf("\n====== [DEBUG: STACK DUMP] ======\n");
            if (vm.sp == 0) {
                printf("(Stack is Empty)\n");
            } else {
                // 倒序打印：从栈顶 (Top) 到 栈底 (Bottom)
                // 这样符合视觉直觉：上面的是新进来的
                for (int i = vm.sp - 1; i >= 0; i--) {
                    uint32_t val = vm.stack[i];
                    
                    // 利用 BitCaster 强转类型，查看它的浮点身姿
                    BitCaster bc;
                    bc.u = val;

                    printf("| [%03d] | HEX: 0x%08X | INT: %-11d | FLT: %-10.5f | CHAR: '%c' |\n", 
                           i,              // 栈索引
                           bc.u,           // 16进制 (看地址或位模式)
                           bc.i,           // 有符号整数 (看计数器或偏移)
                           bc.f,           // 浮点数 (看算术结果)
                           (val >= 32 && val <= 126) ? (char)val : '.'); // 字符 (看字符串)
                }
            }
            printf("====== [ SP: %d | PC: 0x%04X ] ======\n\n", vm.sp, vm.pc - 1);
            break;
        }

        default: {
            printf("Unknown OpCode: 0x%02X at PC=0x%X\n", op, vm.pc - 1);
            vm.running = false;
            break;
        }
    }
}

void check_interrupts() {
    if (vm.int_enable && vm.int_pending) {
        vm.halted = false;
        vm.int_enable = false;
        vm.int_pending = false;
        rpush(vm.base_offset);
        rpush(vm.pc);
        vm.base_offset = 0;
        uint32_t vector_addr = vm.int_vector * 4;
        uint32_t handler_addr = load_u32(vector_addr); 
        vm.pc = handler_addr;
    }
}

// 模拟硬件控制器 - 键盘
void hardware_poll_keyboard() {
    if (_kbhit()) {
        char c = _getch();
        if (c == '\r') {
            c = '\n'; 
        }
        io.data = (uint8_t)c;
        io.status = 1;
        vm.int_pending = true;
        vm.int_vector = KEYBORD_INT_ID; 
    }
}

void start() {
    vm.pc = 0;
    vm.sp = 0;
    vm.rsp = 0;
    vm.running = true;
    vm.halted = false;
    vm.int_enable = true;
    vm.int_pending = false;
    vm.base_offset = 0;
}

void add_keyboard_interrupts() {
    int pc = KEYBORD_INT_START;

    // 输入压栈
    vm.memory[pc++] = LIT;
    store_u32(pc, MMIO_SERIAL_IO);
    pc += 4;
    vm.memory[pc++] = LOAD_B;

    // 打印
    vm.memory[pc++] = LIT;
    store_u32(pc, MMIO_SERIAL_IO);
    pc += 4;
    vm.memory[pc++] = STORE_B;

    // 中断返回
    vm.memory[pc++] = IRET;
}

void add_default_interrupts() {
    int pc = DEFAULT_INT_START;
    vm.memory[pc] = IRET;
}

void fill_other_VIT() {
    for (int i = 0; i < VIT_SIZE / 4; i++) {
        uint32_t addr = i * 4;
        switch (i) {
            case KEYBORD_INT_ID:
                store_u32(addr, KEYBORD_INT_START);
                break;
            default:
                store_u32(addr, DEFAULT_INT_START);
                break;
        }
    }
}

void bios_boot() {
    printf("BIOS: Loading Bootloader from Sector 0 to Address %d...\n", BOOTLOADER_ENTRY);
    fill_other_VIT();
    add_default_interrupts();
    add_keyboard_interrupts();
    fio.disk = fopen("disk.img", "rb+");
    if (!fio.disk) {
        printf("Error: disk.img not found...\nVM Halted.\n");
        exit(1);
    }
    fseek(fio.disk, 0, SEEK_SET);
    fread(&vm.memory[BOOTLOADER_ENTRY], 1, 512, fio.disk);
    vm.pc = BOOTLOADER_ENTRY;
    printf("BIOS: Handover control to Bootloader. PC = %d\n", vm.pc);
}

int main() {
    printf("\nMoYuVM Starting...\n");
    start();
    bios_boot();
    while (vm.running) {
        hardware_poll_keyboard();
        if (vm.halted) {
            _sleep(1); 
        } else {
            step();
        }
        check_interrupts();
    }
    printf("\nMoYuVM Stopped.\n");
    return 0;
}