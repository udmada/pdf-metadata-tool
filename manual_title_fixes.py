#!/usr/bin/env python3
"""Manually fix the titles for the remaining problematic papers."""

import sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).parent / "src"))

from pdf_metadata_tool.metadata_editor import PDFMetadataEditor

papers_dir = Path("/Users/Adam.Du/Library/Mobile Documents/com~apple~CloudDocs/Documents/Papers")

# Correct titles based on manual inspection
manual_corrections = {
    "Abstract - How can historians of philosophy justify spending the preponderance of their.pdf": {
        "Title": "Of Racist Philosophers and Ravens",
        "Author": "Michael B. Gill",
        "Subject": "Journal of Controversial Ideas 2023, 3(1), 2"
    },
    "Abstract - In this article, I reply to comments on my 2020 article \"Scrutinizing the.pdf": {
        "Title": "Scrapping Segregation in Sports: A Response to Critics", 
        "Author": "Jon Pike",
        "Subject": "Journal of Controversial Ideas"
    },
    "D. Abbot,1 A. Bikfalvi,2 A.L. Bleske­Rechek,3 W. Bodmer,4 P. Boghossian 5.pdf": {
        "Title": "In Defense of Merit in Science",
        "Author": "D. Abbot, A. Bikfalvi, A.L. Bleske-Rechek, W. Bodmer, P. Boghossian, et al.",
        "Subject": "Journal of Controversial Ideas"
    },
    "Essay Sex Reassignment and Gender Misfits Harriet Baber 1,.pdf": {
        "Title": "Sex Reassignment and Gender Misfits",
        "Author": "Harriet Baber",
        "Subject": "Journal of Controversial Ideas"
    },
    "Queer Theory and the Transition from Sex to Gender in English Prisons Michael Biggs.pdf": {
        "Title": "Queer Theory and the Transition from Sex to Gender in English Prisons",
        "Author": "Michael Biggs",
        "Subject": "Journal of Controversial Ideas"
    },
    "Reconciliation or Segregation Race as Social Identity in the Cultural Appropriation Debate Olga Thierbach-McLean.pdf": {
        "Title": "Reconciliation or Segregation? Race as Social Identity in the Cultural Appropriation Debate",
        "Author": "Olga Thierbach-McLean", 
        "Subject": "Journal of Controversial Ideas"
    },
    "Sex and Sexual Orientation, Gender and Sexual Preference Raja Halwani.pdf": {
        "Title": "Sex and Sexual Orientation, Gender and Sexual Preference",
        "Author": "Raja Halwani",
        "Subject": "Journal of Controversial Ideas"
    },
    "Sex Categories in Healthcare Contexts ―A Consequentialist Analysis1 Susanna Flavia Boxall and Becky Cox­White.pdf": {
        "Title": "Sex Categories in Healthcare Contexts: A Consequentialist Analysis",
        "Author": "Susanna Flavia Boxall and Becky Cox-White",
        "Subject": "Journal of Controversial Ideas"
    },
    "Thou Shalt Not Create; But If Thou Dost, Thou Shalt Kill A Comment on Belshaw Jeff McMahan.pdf": {
        "Title": "Thou Shalt Not Create; But If Thou Dost, Thou Shalt Kill? A Comment on Belshaw",
        "Author": "Jeff McMahan",
        "Subject": "Journal of Controversial Ideas"
    }
}

def main():
    for filename, metadata in manual_corrections.items():
        pdf_path = papers_dir / filename
        if not pdf_path.exists():
            print(f"File not found: {filename}")
            continue
            
        print(f"Fixing: {filename}")
        print(f"  Setting title: {metadata['Title']}")
        
        try:
            editor = PDFMetadataEditor(pdf_path)
            editor.update_metadata(metadata)
            print(f"  ✓ Updated metadata")
        except Exception as e:
            print(f"  ✗ Error: {e}")

if __name__ == "__main__":
    main()