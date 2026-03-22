#!/usr/bin/env python3
"""Rename the scrutinizing file."""

import sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).parent / "src"))

from pdf_metadata_tool.file_renamer import PDFFileRenamer

papers_dir = Path("/Users/Adam.Du/Library/Mobile Documents/com~apple~CloudDocs/Documents/Papers")

def main():
    # Find the file with glob pattern
    scrutinizing_files = list(papers_dir.glob("*Scrutinizing*"))
    if not scrutinizing_files:
        scrutinizing_files = list(papers_dir.glob("*reply*"))
    
    for pdf_path in scrutinizing_files:
        print(f"Found file: {pdf_path.name}")
        
        # Use our renamer to create proper filename
        renamer = PDFFileRenamer()
        
        # Metadata we set
        metadata = {
            "Title": "Discounting Females, Denying Sex, and Disregarding Dangers from Self-ID: A Reply and a Defense of Open Debate",
            "Author": "Callie H. Burt"
        }
        
        # Get rename preview
        rename_preview = renamer.preview_rename(pdf_path, metadata)
        print(f"Will rename to: {rename_preview['final_name']}")
        
        # Do the rename
        if rename_preview['needs_rename']:
            new_path = Path(rename_preview['final_path'])
            final_path = renamer.rename_file(pdf_path, new_path)
            print(f"✓ Renamed to: {final_path.name}")
        else:
            print("No rename needed")

if __name__ == "__main__":
    main()