import struct
import sys
import os
import re

# ==========================================
# 1. 硬件定义 (保持不变)
# ==========================================
OPCODES = {
    'HLT': 0x00, 'LIT': 0x01, 
    'LOAD': 0x10, 'STORE': 0x11, 'LOAD_B': 0x12, 'STORE_B': 0x13,
    'DUP': 0x20, 'SWAP': 0x21, 'DROP': 0x22, 'PICK': 0x23,
    'ADDI': 0x30, 'SUBI': 0x31, 'MULI': 0x32, 'DIVI': 0x33, 'MOD': 0x34,
    'ADDF': 0x40, 'SUBF': 0x41, 'MULF': 0x42, 'DIVF': 0x43,
    'AND': 0x50, 'OR': 0x51, 'XOR': 0x52, 'NOT': 0x53, 'SHL': 0x54, 'SHR': 0x55,
    'EQI': 0x60, 'NEQI': 0x61, 'LTI': 0x62, 'GTI': 0x63, 'LEI': 0x64, 'GEI': 0x65,
    'JMP': 0x80, 'IJMP': 0x81, 'BZ': 0x82, 'NBZ': 0x83, 'CALL': 0x84, 'RET': 0x85, 'IRET': 0x86,
    'CLI': 0x90, 'STI': 0x91, 'DBG': 0xFF
}

OPS_WITH_ARG = ['LIT', 'JMP', 'BZ', 'NBZ', 'CALL', 'PICK']

BOOTLOADER_START = 3072  # 0x0C00
KERNEL_START     = 4096  # 0x1000

MMIO = {
    'SERIAL_STATUS': 0x100001,
    'SERIAL_DATA':   0x100002,
    'DISK_ADDR_0':   0x100010, # 注意这里最好跟 C 代码宏定义对齐
    'DISK_SECTOR_0': 0x100014,
    'DISK_CMD':      0x100018
}

# ==========================================
# 2. 汇编器核心 (Assembler)
# ==========================================
class Assembler:
    def __init__(self):
        self.labels: dict[str, int] = {}
        self.code_bin = bytearray()

    def parse_value(self, token: str):
        if token.startswith("'") and token.endswith("'"):
            content = token[1:-1] # 去掉引号
            
            # 处理转义字符
            if content == '\\n': return 10  # 换行
            if content == '\\r': return 13  # 回车
            if content == '\\t': return 9   # 制表
            if content == '\\0': return 0   # 空字符
            if content == '\\\\': return 92 # 反斜杠本身
            if content == '\\\'': return 39 # 单引号本身
            
            # 处理普通字符
            if len(content) == 1:
                return ord(content)
            else:
                print(f"Error: Invalid char literal {token}")
                sys.exit(1)
        if token in MMIO: return MMIO[token]
        if token in self.labels: return self.labels[token]
        try:
            if token.startswith('0x') or token.startswith('0X'): 
                return int(token, 16)
            return int(token)
        except:
            return None
        
    def tokenize(self, line: str) -> list[str]:
        # 预处理：去掉注释
        if '//' in line: line = line.split('//')[0]
        if ';' in line: line = line.split(';')[0]
        line = line.strip()
        if not line: return []

        # 使用正则分词：匹配 [单引号包围的字符串] 或 [非空白字符序列]
        # 这样就能正确识别 ' ' (空格) 这种会被 split() 吞掉的字符
        return re.findall(r"(?:'[^']*'|\S+)", line)

    def assemble(self, source_code: str, start_offset: int):
        lines = source_code.strip().split('\n')

        # Pass 1: 记录标签
        current_pc = start_offset
        for line in lines:
            tokens = self.tokenize(line)
            if not tokens: continue
            if tokens[0].endswith(':'):
                label_name = tokens[0][:-1]
                self.labels[label_name] = current_pc
                tokens = tokens[1:]
                if not tokens: continue

            op = tokens[0].upper()
            if op not in OPCODES:
                print(f"Error: Unknown instruction '{op}'")
                sys.exit(1)
            
            current_pc += 1
            if op in OPS_WITH_ARG:
                current_pc += 4

        # Pass 2: 生成代码
        current_pc = start_offset
        for line in lines:
            tokens = self.tokenize(line)
            if not tokens: continue
            if tokens[0].endswith(':'):
                tokens = tokens[1:]
                if not tokens: continue

            op = tokens[0].upper()
            self.code_bin.append(OPCODES[op])
            
            if op in OPS_WITH_ARG:
                if len(tokens) < 2:
                    print(f"Error: Instruction {op} requires an argument.")
                    sys.exit(1)
                arg_str = tokens[1]
                arg_val = self.parse_value(arg_str)
                if arg_val is None:
                    print(f"Error: Undefined label or value '{arg_str}'")
                    sys.exit(1)
                self.code_bin.extend(struct.pack('>I', arg_val))

        return self.code_bin

# ==========================================
# 3. 主程序：读取文件并构建
# ==========================================
def read_asm_file(filename):
    if not os.path.exists(filename):
        print(f"Error: File '{filename}' not found.")
        sys.exit(1)
    with open(filename, 'r', encoding='utf-8') as f:
        return f.read()

def make_disk():
    # 1. 读取外部文件
    print(">>> Reading boot.asm...")
    boot_src = read_asm_file("boot.asm")
    
    print(">>> Reading kernel.asm...")
    kernel_src = read_asm_file("kernel.asm")

    # 2. 汇编 Bootloader
    print(">>> Assembling Bootloader...")
    asm_boot = Assembler()
    bin_boot = asm_boot.assemble(boot_src, BOOTLOADER_START)
    
    # 3. 汇编 Kernel
    print(">>> Assembling Kernel...")
    asm_kernel = Assembler()
    bin_kernel = asm_kernel.assemble(kernel_src, KERNEL_START)

    print(f"Bootloader Size: {len(bin_boot)} bytes")
    print(f"Kernel Size:     {len(bin_kernel)} bytes")

    if len(bin_boot) > 512:
        print(f"Error: Bootloader too big! ({len(bin_boot)} > 512)")
        return

    # 4. 写入镜像
    sector_0 = bin_boot + b'\x00' * (512 - len(bin_boot))
    total_size = 1024 * 1024 

    with open("disk.img", "wb") as f:
        f.write(sector_0)       # Sector 0
        f.write(bin_kernel)     # Sector 1 ~ N
        
        current_size = f.tell()
        padding = total_size - current_size
        f.write(b'\x00' * padding)
        
    print(f"\n>>> Success! 'disk.img' build complete.")

if __name__ == "__main__":
    make_disk()