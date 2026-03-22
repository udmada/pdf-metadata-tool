"""PDF metadata editing and writing."""

import shutil
from pathlib import Path
from typing import Dict, Optional

from pypdf import PdfReader, PdfWriter


class PDFMetadataEditor:
    """Edit and write PDF metadata."""
    
    def __init__(self, pdf_path: Path):
        self.pdf_path = pdf_path
        self.backup_path: Optional[Path] = None
    
    def create_backup(self) -> Path:
        """Create a backup of the original PDF."""
        # Create backups directory if it doesn't exist
        backups_dir = self.pdf_path.parent / 'backups'
        backups_dir.mkdir(exist_ok=True)
        
        # Create backup filename in the backups directory
        backup_filename = self.pdf_path.stem + '.backup.pdf'
        backup_path = backups_dir / backup_filename
        
        counter = 1
        while backup_path.exists():
            backup_filename = self.pdf_path.stem + f'.backup{counter}.pdf'
            backup_path = backups_dir / backup_filename
            counter += 1
        
        shutil.copy2(self.pdf_path, backup_path)
        self.backup_path = backup_path
        return backup_path
    
    def restore_from_backup(self) -> bool:
        """Restore PDF from backup."""
        if not self.backup_path or not self.backup_path.exists():
            return False
        
        shutil.copy2(self.backup_path, self.pdf_path)
        self.backup_path.unlink()  # Remove backup
        self.backup_path = None
        return True
    
    def remove_backup(self) -> bool:
        """Remove backup file."""
        if not self.backup_path or not self.backup_path.exists():
            return False
        
        self.backup_path.unlink()
        self.backup_path = None
        return True
    
    def update_metadata(self, metadata: Dict[str, str], create_backup: bool = True) -> bool:
        """Update PDF metadata with new values."""
        try:
            if create_backup:
                self.create_backup()
            
            # Read the PDF
            reader = PdfReader(self.pdf_path)
            writer = PdfWriter()
            
            # Copy all pages, handling PyPDF annotation parsing errors
            try:
                for page in reader.pages:
                    writer.add_page(page)
            except KeyError as e:
                if str(e) == "'/D'":
                    # This PDF has problematic annotations that PyPDF can't handle
                    # For now, skip the full PDF rewrite and just update external metadata
                    print("Warning: PDF contains problematic annotations, skipping internal metadata update")
                    print("  Using exiftool for external metadata only")
                    
                    # Only update keywords using exiftool if Keywords are present
                    if 'Keywords' in metadata and metadata['Keywords']:
                        self._set_preview_compatible_keywords(metadata['Keywords'])
                        return True
                    else:
                        print("  No keywords to update, skipping...")
                        return False
                else:
                    raise
            
            # Prepare metadata for PyPDF
            pdf_metadata = {}
            
            # Map common metadata fields to PDF standard fields
            field_mapping = {
                'Title': '/Title',
                'Author': '/Author', 
                'Subject': '/Subject',
                'Keywords': '/Keywords',
                'Creator': '/Creator',
                'Producer': '/Producer',
                'CreationDate': '/CreationDate',
                'ModDate': '/ModDate'
            }
            
            # Copy existing metadata first, converting all values to strings
            if reader.metadata:
                for key, value in reader.metadata.items():
                    # Convert IndirectObject and other types to strings
                    pdf_metadata[key] = str(value) if value is not None else None
            
            # Update with new metadata
            for key, value in metadata.items():
                if key in field_mapping:
                    pdf_metadata[field_mapping[key]] = value
                else:
                    # For custom fields, add PDF prefix if not present
                    pdf_key = key if key.startswith('/') else f'/{key}'
                    pdf_metadata[pdf_key] = value
            
            # Set metadata on writer
            writer.add_metadata(pdf_metadata)
            
            # Write to temporary file first
            temp_path = self.pdf_path.with_suffix('.tmp.pdf')
            with open(temp_path, 'wb') as output_file:
                writer.write(output_file)
            
            # Replace original with temp file
            temp_path.replace(self.pdf_path)
            
            # For keywords, also use exiftool to set XMP/IPTC fields that Preview.app recognizes
            if 'Keywords' in metadata and metadata['Keywords']:
                self._set_preview_compatible_keywords(metadata['Keywords'])
            
            return True
            
        except Exception as e:
            # If backup exists, restore it
            if self.backup_path and self.backup_path.exists():
                self.restore_from_backup()
            raise RuntimeError(f"Failed to update PDF metadata: {e}")
    
    def set_title(self, title: str) -> bool:
        """Set PDF title."""
        return self.update_metadata({'Title': title})
    
    def set_author(self, author: str) -> bool:
        """Set PDF author."""
        return self.update_metadata({'Author': author})
    
    def set_subject(self, subject: str) -> bool:
        """Set PDF subject."""
        return self.update_metadata({'Subject': subject})
    
    def enhance_metadata(self, extracted_metadata: Dict[str, str], 
                        preserve_existing: bool = True) -> bool:
        """Enhance PDF metadata with extracted information."""
        if not extracted_metadata:
            return False
        
        try:
            # Read current metadata if preserving
            current_metadata = {}
            if preserve_existing:
                reader = PdfReader(self.pdf_path)
                if reader.metadata:
                    current_metadata = {
                        key.replace('/', ''): str(value) if value is not None else None
                        for key, value in reader.metadata.items()
                    }
            
            # Merge metadata (extracted overwrites current if not preserving)
            final_metadata = current_metadata.copy() if preserve_existing else {}
            
            # Add/update with extracted metadata
            for key, value in extracted_metadata.items():
                if value and (not preserve_existing or key not in final_metadata):
                    final_metadata[key] = value
            
            # Update the PDF
            return self.update_metadata(final_metadata)
            
        except Exception as e:
            raise RuntimeError(f"Failed to enhance PDF metadata: {e}")
    
    def _set_preview_compatible_keywords(self, keywords: str) -> bool:
        """Set keywords using exiftool in formats that Preview.app recognizes."""
        try:
            import subprocess
            
            # Deduplicate keywords before setting them
            clean_keywords = self._deduplicate_keywords(keywords)
            
            # First clear all existing keyword fields to avoid duplication
            clear_cmd = [
                'exiftool',
                '-overwrite_original',
                '-XMP:Subject=',
                '-XMP:TagsList=',
                '-IPTC:Keywords=',
                '-Keywords=',
                str(self.pdf_path)
            ]
            subprocess.run(clear_cmd, capture_output=True, text=True)
            
            # Then set the clean keywords in multiple formats for maximum compatibility
            set_cmd = [
                'exiftool',
                '-overwrite_original',
                f'-XMP:Subject={clean_keywords}',
                f'-XMP:TagsList={clean_keywords}', 
                f'-IPTC:Keywords={clean_keywords}',
                f'-Keywords={clean_keywords}',  # This is the field Preview.app recognizes
                str(self.pdf_path)
            ]
            
            result = subprocess.run(set_cmd, capture_output=True, text=True)
            
            # Debug output
            if result.returncode != 0:
                print(f"ExifTool error: {result.stderr}")
            else:
                print(f"ExifTool success: Keywords set for {self.pdf_path.name}")
                
            return result.returncode == 0
            
        except Exception as e:
            print(f"Warning: Could not set Preview.app compatible keywords: {e}")
            return False
    
    def _deduplicate_keywords(self, keywords_string: str) -> str:
        """Remove duplicate keywords from a comma or semicolon-separated string."""
        if not keywords_string:
            return ''
        
        # Split by comma, semicolon, pipe, or other separators and clean up
        if ';' in keywords_string:
            keywords = [kw.strip() for kw in keywords_string.split(';')]
        elif '|' in keywords_string:
            keywords = [kw.strip() for kw in keywords_string.split('|')]  # Handle pipe separator
        else:
            keywords = [kw.strip() for kw in keywords_string.split(',')]
        
        # Deduplicate case-insensitively while preserving original case
        seen = set()
        deduplicated = []
        
        for keyword in keywords:
            # Clean up keyword - remove quotes, punctuation, and whitespace
            keyword = keyword.strip().strip('.,;"\'')  # Remove quotes and punctuation
            if keyword and keyword.lower() not in seen:
                seen.add(keyword.lower())
                deduplicated.append(keyword)
        
        # Always return comma-separated for Preview.app compatibility
        return ', '.join(deduplicated)