#!/usr/bin/env python3
"""Rename the timeout PDF with proper formatting."""

import sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).parent / "src"))

from pdf_metadata_tool.file_renamer import PDFFileRenamer

def main():
    pdf_path = Path("/Users/Adam.Du/Library/Mobile Documents/com~apple~CloudDocs/Documents/Pedohebephilia and Perceived Non-coercive Childhood Sexual Experiences- Two Non-matched Case-Control Studies.pdf")
    
    if not pdf_path.exists():
        print(f"File not found: {pdf_path}")
        return
    
    print(f"Renaming: {pdf_path.name}")
    
    # The metadata we just set
    metadata = {
        "Title": "Pedohebephilia and Perceived Non-coercive Childhood Sexual Experiences: Two Non-matched Case-Control Studies",
        "Author": "",
    }
    
    renamer = PDFFileRenamer()
    rename_preview = renamer.preview_rename(pdf_path, metadata)
    
    if rename_preview['needs_rename']:
        new_path = Path(rename_preview['final_path'])
        final_path = renamer.rename_file(pdf_path, new_path)
        print(f"✓ Renamed to: {final_path.name}")
    else:
        print("No rename needed")

if __name__ == "__main__":
    main()