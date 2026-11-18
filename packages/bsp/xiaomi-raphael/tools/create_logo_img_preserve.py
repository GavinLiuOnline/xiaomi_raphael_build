#!/usr/bin/env python3
"""
保持原始头部结构的 logo.img 打包工具
只替换 BMP 数据，保持原始的头部结构和偏移位置
"""

import os
import sys
import struct

def create_logo_img_preserve_header(bmp_dir, output_path, original_logo):
    """保持原始头部结构，只替换 BMP 数据"""

    if not original_logo or not os.path.exists(original_logo):
        print("错误: 需要提供原始 logo.img 文件")
        return False

    # 查找所有 BMP 文件
    bmp_files = []
    for f in sorted(os.listdir(bmp_dir)):
        if f.lower().endswith('.bmp'):
            bmp_files.append(os.path.join(bmp_dir, f))

    if not bmp_files:
        print("错误: 未找到 BMP 文件")
        return False

    print(f"找到 {len(bmp_files)} 个 BMP 文件")

    # 读取原始文件
    with open(original_logo, 'rb') as f:
        orig_data = bytearray(f.read())

    print(f"原始文件大小: {len(orig_data)} bytes")

    # 查找原始文件中所有 BMP 文件的位置
    bmp_offsets_orig = []
    offset = 0

    while offset < len(orig_data) - 2:
        if orig_data[offset:offset+2] == b'BM':
            bmp_size = struct.unpack('<I', orig_data[offset+2:offset+6])[0]
            bmp_offsets_orig.append((offset, bmp_size))
            print(f"原始 BMP #{len(bmp_offsets_orig)-1}: 偏移 0x{offset:x}, 大小 {bmp_size}")
            offset += bmp_size
        else:
            offset += 1

    print(f"原始文件包含 {len(bmp_offsets_orig)} 个 BMP 文件")

    # 检查 BMP 文件数量是否匹配
    if len(bmp_files) != len(bmp_offsets_orig):
        print(f"警告: BMP 文件数量不匹配（原始 {len(bmp_offsets_orig)} 个，新 {len(bmp_files)} 个）")
        print("将只替换前 {min(len(bmp_files), len(bmp_offsets_orig))} 个 BMP 文件")

    # 读取新的 BMP 文件
    bmp_data_list = []
    for bmp_path in bmp_files:
        with open(bmp_path, 'rb') as f:
            bmp_data = f.read()
        bmp_data_list.append(bmp_data)
        print(f"{bmp_path}: {len(bmp_data)} bytes")

    # 替换 BMP 数据
    num_replace = min(len(bmp_files), len(bmp_offsets_orig))

    for i in range(num_replace):
        orig_offset, orig_size = bmp_offsets_orig[i]
        new_size = len(bmp_data_list[i])

        print(f"\n替换 BMP #{i}:")
        print(f"  原始位置: 0x{orig_offset:x}, 原始大小: {orig_size}")
        print(f"  新大小: {new_size}")

        if new_size != orig_size:
            print(f"  警告: BMP 文件大小不匹配！")
            print(f"  原始: {orig_size} bytes")
            print(f"  新: {new_size} bytes")
            print(f"  差异: {new_size - orig_size} bytes")

            # 如果新文件更大，需要扩展文件
            if new_size > orig_size:
                print(f"  需要扩展文件 {new_size - orig_size} bytes")
                # 在原始位置插入额外空间
                orig_data[orig_offset+orig_size:orig_offset+orig_size] = bytearray(new_size - orig_size)
            # 如果新文件更小，需要缩小文件
            elif new_size < orig_size:
                print(f"  需要缩小文件 {orig_size - new_size} bytes")
                # 删除多余空间
                del orig_data[orig_offset+new_size:orig_offset+orig_size]

        # 替换 BMP 数据
        orig_data[orig_offset:orig_offset+new_size] = bmp_data_list[i]
        print(f"  已替换")

    # 写入文件
    with open(output_path, 'wb') as f:
        f.write(orig_data)

    print(f"\n已生成: {output_path} (大小: {len(orig_data)} bytes)")
    print(f"原始头部结构已保持不变")
    return True

def main():
    if len(sys.argv) < 3:
        print("用法: python3 create_logo_img_preserve.py <BMP目录> <输出文件> <原始logo.img>")
        print("示例: python3 create_logo_img_preserve.py logo_bmp logo_new.img logo.img")
        sys.exit(1)

    bmp_dir = sys.argv[1]
    output_path = sys.argv[2]
    original_logo = sys.argv[3]

    create_logo_img_preserve_header(bmp_dir, output_path, original_logo)

if __name__ == '__main__':
    main()