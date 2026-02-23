import struct
import sys
import os
import re

# 硬件定义
OPCODES = {
    'HLT': 0x00, 'LIT': 0x01, 
    'LOAD': 0x10, 'STORE': 0x11, 'LOAD_B': 0x12, 'STORE_B': 0x13,
    'DUP': 0x20, 'SWAP': 0x21, 'DROP': 0x22, 
    'PES': 0x23, 'PEF': 0x24, 
    'ADDI': 0x30, 'SUBI': 0x31, 'MULI': 0x32, 'DIVI': 0x33, 'MOD': 0x34, 'ITF': 0x35,
    'ADDF': 0x40, 'SUBF': 0x41, 'MULF': 0x42, 'DIVF': 0x43, 'FTI': 0x44,
    'AND': 0x50, 'OR': 0x51, 'XOR': 0x52, 'NOT': 0x53, 'SHL': 0x54, 'SHR': 0x55,
    'EQI': 0x60, 'NEQI': 0x61, 'LTI': 0x62, 'GTI': 0x63, 'LEI': 0x64, 'GEI': 0x65,
    'EQF': 0x70, 'NEQF': 0x71, 'LTF': 0x72, 'GTF': 0x73, 'LEF': 0x74, 'GEF': 0x75,
    'JMP': 0x80, 'IJMP': 0x81, 'BZ': 0x82, 'NBZ': 0x83, 
    'CALL': 0x84, 'RET': 0x85, 'IRET': 0x86,
    'CLI': 0x90, 'STI': 0x91, 'INT': 0x92,
    'SR': 0xA0, 'GR': 0xA1, 'STF': 0xA2,
    'DBG': 0xFF
}

OPS_WITH_ARG = {
    'LIT', 'PES', 'PEF', 'JMP', 'BZ', 'NBZ', 'CALL', 'INT', 'SR', 'GR'
}

REGISTERS = {
    'SP': 0, 'FP': 1, 'BASE': 2, 'LIMIT': 3, 'RV': 4,
}

BOOTLOADER_START = 3072  # 0x0C00
KERNEL_START     = 4096  # 0x1000

MMIO = {
    'SERIAL_STATUS': 0x100001,
    'SERIAL_DATA':   0x100002,
    'DISK_ADDR_0':   0x100010,
    'DISK_SECTOR_0': 0x100014,
    'DISK_CMD':      0x100018
}

# 汇编器
class Assembler:
    def __init__(self):
        self.labels = {}
        self.constants = {}
        self.code_bin = bytearray()

    def parse_string_literal(self, token: str) -> bytes:
        """处理 "Hello\n" 这种双引号字符串，返回字节串 (带\0)"""
        content = token[1:-1]
        content = content.replace('\\n', '\n').replace('\\r', '\r').replace('\\t', '\t').replace('\\0', '\0')
        return content.encode('utf-8') + b'\x00' # 自动追加 \0

    def parse_value(self, token: str):
        # 1. 字符字面量 'A'
        if token.startswith("'") and token.endswith("'"):
            content = token[1:-1]
            if content == '\\n': return 10
            if content == '\\r': return 13
            if content == '\\0': return 0
            if len(content) == 1: return ord(content)

        # 2. 寄存器
        if token.upper() in REGISTERS: return REGISTERS[token.upper()]

        # 3. 常量 (新增!)
        if token in self.constants: return self.constants[token]

        # 4. 标签
        if token in self.labels: return self.labels[token]
        
        # 5. 数字
        try:
            if token.lower().startswith('0x'): return int(token, 16)
            return int(token)
        except:
            return None
        
    def tokenize(self, line: str) -> list[str]:
        # 去掉注释
        if '//' in line: line = line.split('//')[0]
        if ';' in line: line = line.split(';')[0]
        line = line.strip()
        if not line: return []
        
        # 正则增强：支持 "String" (双引号) 和 'C' (单引号)
        # 匹配模式： "..." 或 '...' 或 非空白字符
        return re.findall(r"(?:\"[^\"]*\"|'[^']*'|\S+)", line)

    def assemble(self, source_code: str, start_offset: int):
        lines = source_code.strip().split('\n')
        self.labels = {}
        self.constants = {}
        self.code_bin = bytearray()

        # --- Pass 1: 扫描标签 & 记录常量 ---
        current_pc = start_offset
        for line in lines:
            tokens = self.tokenize(line)
            if not tokens: continue
            
            # 处理标签 label:
            if tokens[0].endswith(':'):
                label_name = tokens[0][:-1]
                self.labels[label_name] = current_pc
                tokens = tokens[1:]
                if not tokens: continue

            op = tokens[0]

            # 伪指令：CONST Name Value
            if op.upper() == 'CONST':
                if len(tokens) < 3:
                    print(f"Error: CONST requires name and value. Line: {line}")
                    sys.exit(1)
                name = tokens[1]
                val = self.parse_value(tokens[2])
                if val is None:
                    try:
                        if tokens[2].lower().startswith('0x'): val = int(tokens[2], 16)
                        else: val = int(tokens[2])
                    except:
                        print(f"Error: Invalid constant value '{tokens[2]}'")
                        sys.exit(1)
                self.constants[name] = val
                continue

            # 伪指令：STRING "..."
            if op.upper() == 'STRING':
                if len(tokens) < 2:
                    print(f"Error: STRING requires content. Line: {line}")
                    sys.exit(1)
                str_bytes = self.parse_string_literal(tokens[1])
                current_pc += len(str_bytes)
                continue

            # 普通指令
            if op.upper() not in OPCODES:
                print(f"Error: Unknown instruction '{op}' in line: {line}")
                sys.exit(1)
            
            current_pc += 1
            if op.upper() in OPS_WITH_ARG:
                current_pc += 4

        # --- Pass 2: 生成机器码 ---
        current_pc = start_offset
        for line in lines:
            tokens = self.tokenize(line)
            if not tokens: continue
            if tokens[0].endswith(':'): tokens = tokens[1:]
            if not tokens: continue

            op = tokens[0].upper()

            # 处理 CONST (Pass 2 直接忽略，因为已记录)
            if op == 'CONST': continue

            # 处理 STRING
            if op == 'STRING':
                str_bytes = self.parse_string_literal(tokens[1])
                self.code_bin.extend(str_bytes)
                continue

            # 普通指令
            self.code_bin.append(OPCODES[op])
            
            if op in OPS_WITH_ARG:
                arg_str = tokens[1]
                arg_val = self.parse_value(arg_str) # 这里可以查到 CONST 了
                
                if arg_val is None:
                    print(f"Error: Undefined symbol '{arg_str}'")
                    sys.exit(1)
                
                try:
                    self.code_bin.extend(struct.pack('>i', arg_val))
                except struct.error:
                    self.code_bin.extend(struct.pack('>I', arg_val))

        return self.code_bin

# 3. 读取文件并构建
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