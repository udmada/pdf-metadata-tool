#!/usr/bin/env python3
"""
Find and optionally remove files that contain 'Adam.Du' in their content.
These appear to be debug/test files created during development.
"""

import os
from pathlib import Path


def find_files_with_content(directory: str, search_string: str) -> list[Path]:
    """Find all files containing the given string."""
    results = []
    for root, _, files in os.walk(directory):
        # Skip hidden directories and .git
        if '.git' in root or '.claude' in root:
            continue

        for filename in files:
            filepath = Path(root) / filename
            try:
                with open(filepath, 'r', encoding='utf-8', errors='ignore') as f:
                    content = f.read()
                    if search_string in content:
                        results.append(filepath)
            except (PermissionError, UnicodeDecodeError):
                continue

    return sorted(results)


def main():
    directory = '.'
    search_string = 'Adam.Du'

    files = find_files_with_content(directory, search_string)

    print(f"Found {len(files)} file(s) containing '{search_string}':\n")
    for filepath in files:
        rel_path = filepath.relative_to(Path.cwd())
        print(f"  {rel_path}")

    # Ask user if they want to remove them
    if files:
        response = input("\nRemove these files? (y/N): ")
        if response.lower() == 'y':
            removed = []
            failed = []
            for filepath in files:
                try:
                    filepath.unlink()
                    removed.append(str(filepath))
                    print(f"  Removed: {filepath}")
                except Exception as e:
                    failed.append((str(filepath), str(e)))

            print(f"\nRemoved {len(removed)} file(s)")
            if failed:
                print("\nFailed to remove:")
                for path, error in failed:
                    print(f"  {path}: {error}")


if __name__ == '__main__':
    main()
