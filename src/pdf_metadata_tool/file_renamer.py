"""PDF file renaming utilities."""

import re
from pathlib import Path
from typing import Dict, Optional, Tuple


class PDFFileRenamer:
    """Handle PDF file renaming based on metadata."""
    
    def __init__(self, max_filename_length: int = 200):
        self.max_filename_length = max_filename_length
    
    def clean_filename_part(self, text: str) -> str:
        """Clean text for use in filename."""
        if not text:
            return ""
        
        # First, decode HTML entities and fix common escape issues
        import html
        text = html.unescape(text)
        
        # Remove HTML tags but preserve their content (e.g., <i>n</i> becomes n)
        text = re.sub(r'<[^>]+>', '', text)
        
        # Fix common HTML entities that html.unescape might miss
        text = text.replace('„&ndash;„', ' - ')
        text = text.replace('&ndash;', '-')
        text = text.replace('&mdash;', '—')
        text = text.replace('&amp;', '&')
        text = text.replace('&lt;', '<')
        text = text.replace('&gt;', '>')
        text = text.replace('&quot;', '"')
        text = text.replace('&#x02010;', '-')
        text = text.replace('&#x0003D;', '=')
        
        # Replace problematic characters for cross-platform compatibility
        # On macOS, colons are converted to forward slashes in Finder, so replace with dash
        text = text.replace(':', ' -')  # Replace colon with dash for macOS compatibility
        text = re.sub(r'[<>"/\\|?*]', '', text)  # Windows/Unix forbidden chars (removed colon)
        text = re.sub(r'[\x00-\x1f\x7f-\x9f]', '', text)  # Control characters
        text = re.sub(r'\s+', ' ', text)  # Normalize whitespace
        text = text.strip()
        
        # Remove leading/trailing periods and spaces
        text = text.strip('. ')
        
        return text
    
    def truncate_text(self, text: str, max_length: int) -> str:
        """Truncate text to fit within length, preserving word boundaries."""
        if len(text) <= max_length:
            return text
        
        # Try to truncate at word boundary
        truncated = text[:max_length - 3]  # Leave room for '...'
        last_space = truncated.rfind(' ')
        
        if last_space > max_length * 0.7:  # Only truncate at word if it's not too early
            truncated = truncated[:last_space]
        
        return truncated + '...'
    
    def extract_first_author_surname(self, authors: str) -> Optional[str]:
        """Extract the surname of the first author."""
        if not authors:
            return None
        
        # Split by common author separators
        author_list = re.split(r'[,;]\s*(?:and\s+)?|\s+and\s+', authors.strip())
        if not author_list:
            return None
        
        first_author = author_list[0].strip()
        
        # Handle formats like "Last, First" or "First Last"
        if ',' in first_author:
            # Format: "Last, First" - take the first part
            surname = first_author.split(',')[0].strip()
        else:
            # Format: "First Last" or "First Middle Last" - take the last part
            name_parts = first_author.split()
            if name_parts:
                surname = name_parts[-1]
            else:
                return None
        
        # Clean and validate surname
        surname = self.clean_filename_part(surname)
        if len(surname) < 2:  # Too short to be meaningful
            return None
        
        return surname
    
    def generate_filename(self, metadata: Dict[str, str]) -> str:
        """Generate a clean filename from metadata."""
        title = metadata.get('Title', '').strip()
        subject = metadata.get('Subject', '').strip()
        
        # Use title first, then subject as fallback
        filename_base = title or subject or "Unknown_Title"
        
        # Clean the filename
        clean_filename = self.clean_filename_part(filename_base)
        
        if not clean_filename or clean_filename == "Unknown_Title":
            clean_filename = "Unknown_Title"
        
        # Ensure filename isn't too long
        max_base_length = self.max_filename_length - 4  # Reserve space for .pdf
        if len(clean_filename) > max_base_length:
            clean_filename = self.truncate_text(clean_filename, max_base_length)
        
        return clean_filename + ".pdf"
    
    def suggest_rename(self, pdf_path: Path, metadata: Dict[str, str]) -> Tuple[Path, bool]:
        """Suggest a new filename and path for the PDF."""
        new_filename = self.generate_filename(metadata)
        new_path = pdf_path.parent / new_filename
        
        # Check if rename is needed
        needs_rename = pdf_path.name != new_filename
        
        return new_path, needs_rename
    
    def find_available_filename(self, desired_path: Path) -> Path:
        """Find an available filename if the desired one exists."""
        if not desired_path.exists():
            return desired_path
        
        base_name = desired_path.stem
        suffix = desired_path.suffix
        parent = desired_path.parent
        counter = 1
        
        while True:
            new_name = f"{base_name} ({counter}){suffix}"
            new_path = parent / new_name
            if not new_path.exists():
                return new_path
            counter += 1
            
            # Safety check to avoid infinite loop
            if counter > 1000:
                raise RuntimeError(f"Could not find available filename for {desired_path}")
    
    def rename_file(self, old_path: Path, new_path: Path, 
                   handle_conflicts: bool = True) -> Path:
        """Rename a file, handling conflicts if needed."""
        if not old_path.exists():
            raise FileNotFoundError(f"Source file not found: {old_path}")
        
        # Handle filename conflicts
        final_path = new_path
        if handle_conflicts and new_path.exists() and new_path != old_path:
            final_path = self.find_available_filename(new_path)
        
        # Perform the rename
        old_path.rename(final_path)
        return final_path
    
    def preview_rename(self, pdf_path: Path, metadata: Dict[str, str]) -> Dict[str, str]:
        """Preview what the rename would do without executing it."""
        new_path, needs_rename = self.suggest_rename(pdf_path, metadata)
        
        preview = {
            'current_name': pdf_path.name,
            'suggested_name': new_path.name,
            'needs_rename': needs_rename,
            'current_path': str(pdf_path),
            'suggested_path': str(new_path)
        }
        
        # Check for conflicts
        if new_path.exists() and new_path != pdf_path:
            available_path = self.find_available_filename(new_path)
            preview['conflict_detected'] = True
            preview['final_name'] = available_path.name
            preview['final_path'] = str(available_path)
        else:
            preview['conflict_detected'] = False
            preview['final_name'] = new_path.name
            preview['final_path'] = str(new_path)
        
        return preview