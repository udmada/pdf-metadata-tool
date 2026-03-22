"""PDF metadata extraction and analysis."""

import re
from pathlib import Path
from typing import Dict, List, Optional, Tuple

import pdfplumber
from pypdf import PdfReader

from .doi_lookup import DOILookup


class PDFMetadataExtractor:
    """Extract and analyze PDF metadata and content."""
    
    def __init__(self, pdf_path: Path, enable_doi_lookup: bool = True):
        self.pdf_path = pdf_path
        self._reader: Optional[PdfReader] = None
        self._plumber: Optional[pdfplumber.PDF] = None
        self.enable_doi_lookup = enable_doi_lookup
        self._doi_lookup: Optional[DOILookup] = None
    
    @property
    def reader(self) -> PdfReader:
        if self._reader is None:
            self._reader = PdfReader(self.pdf_path)
        return self._reader
    
    @property
    def plumber(self) -> pdfplumber.PDF:
        if self._plumber is None:
            self._plumber = pdfplumber.open(self.pdf_path)
        return self._plumber
    
    @property
    def doi_lookup(self) -> DOILookup:
        if self._doi_lookup is None:
            self._doi_lookup = DOILookup()
        return self._doi_lookup
    
    def get_existing_metadata(self) -> Dict[str, str]:
        """Extract existing PDF metadata."""
        metadata = {}
        if self.reader.metadata:
            for key, value in self.reader.metadata.items():
                if value:
                    # Remove PDF metadata prefix
                    clean_key = key.replace("/", "").title()
                    clean_value = str(value)
                    
                    # Clean HTML formatting from title and other text fields
                    if clean_key in ['Title', 'Subject', 'Keywords']:
                        clean_value = self._clean_title_formatting(clean_value)
                    
                    metadata[clean_key] = clean_value
        return metadata
    
    def extract_title_from_content(self) -> Optional[str]:
        """Extract title from PDF content using various heuristics."""
        try:
            first_page = self.plumber.pages[0]
            text = first_page.extract_text()
            
            if not text:
                return None
            
            lines = [line.strip() for line in text.split('\n') if line.strip()]
            
            # Skip common headers/footers
            skip_patterns = [
                r'^page\s+\d+',
                r'^\d+\s*$',
                r'^vol\.',
                r'^volume',
                r'^doi:',
                r'^http',
                r'^www\.',
                r'©\s*\d{4}',
                r'elsevier',
                r'springer',
                r'nature',
                r'wiley',
                r'published',
                r'received',
                r'accepted',
                r'available online',
                r'^research\s*$',
                r'^open access\s*$',
                r'^abstract\s*$',
                r'^background\s*$',
                r'^methods\s*$',
                r'^results\s*$',
                r'^conclusion\s*$',
                r'^keywords\s*$',
                r'^correspondence:',
                r'^\*correspondence',
                r'^author',
                r'^affiliation',
                r'issn:',
                r'journal homepage:',
                r'tandfonline\.com',
                r'to cite this article:',
                r'to link to this article:',
                r'published online:',
                r'submit your article',
                r'view related articles',
                r'view crossmark',
                r'full terms & conditions',
                r'journalcode='
            ]
            
            # Find potential title lines
            title_candidates = []
            
            # First, look for lines that appear before "Abstract" section
            abstract_index = None
            for i, line in enumerate(lines):
                if re.match(r'^abstract\s*$', line.lower()):
                    abstract_index = i
                    break
            
            # Limit search to lines before abstract or first 20 lines
            search_limit = min(abstract_index or 20, 20)
            
            for i, line in enumerate(lines[:search_limit]):
                line_lower = line.lower()
                
                # Skip if matches skip patterns
                if any(re.search(pattern, line_lower) for pattern in skip_patterns):
                    continue
                
                # Skip very short lines
                if len(line) < 15:
                    continue
                
                # Skip lines that look like author names, affiliations, or correspondence
                if (
                    # Improved author name patterns (catches more variations)
                    re.match(r'^[A-Z][a-z]+(\s+[A-Z][a-z]*\.?)?\s+[A-Z][a-z]+(\s+\d+)?(\s*[,*]+\s*)?$', line) or
                    re.match(r'^[A-Z][a-z]+\s+[A-Z]\.\s*[A-Z][a-z]+', line) or
                    # Multi-author patterns
                    ' and ' in line and re.search(r'[A-Z][a-z]+\s+[A-Z][a-z]+', line) or
                    # Correspondence patterns (with flexible spacing)
                    'correspondingauthor' in line.replace(' ', '').lower() or
                    'corresponding author' in line_lower or
                    line_lower.startswith('*') or
                    '@' in line or
                    # Institution patterns (with flexible spacing)  
                    'universityof' in line.replace(' ', '').lower() or
                    'department' in line_lower or 'university' in line_lower or 
                    'hospital' in line_lower or 'institute' in line_lower or
                    'college' in line_lower or
                    # Abstract patterns that got mistaken for titles
                    line_lower.startswith('abstract:') or
                    # Submission info
                    'submitted:' in line_lower or 'accepted:' in line_lower
                ):
                    continue
                
                # Look for title-like characteristics
                title_score = 0
                
                # Longer lines are more likely to be titles
                if len(line) > 60:
                    title_score += 3
                elif len(line) > 40:
                    title_score += 2
                elif len(line) > 25:
                    title_score += 1
                
                # Doesn't end with period (most titles don't)
                if not line.endswith('.'):
                    title_score += 2
                
                # Not numbered
                if not re.match(r'^\d+\.', line):
                    title_score += 1
                
                # Has capital letters but not all caps
                if line != line.upper() and line != line.lower():
                    title_score += 1
                
                # Strong bonus for being in the top few lines (likely title position)
                if i < 3:
                    title_score += 5  # Much higher bonus for very early lines
                elif i < 5:
                    title_score += 3
                elif i < 10:
                    title_score += 1
                
                # Contains research-related words
                research_words = ['risk factors', 'study', 'analysis', 'effect', 'association', 'impact', 
                                'treatment', 'intervention', 'comparison', 'evaluation', 'among', 'between']
                if any(word in line_lower for word in research_words):
                    title_score += 2
                
                # Bonus for typical academic title patterns
                if ('among' in line_lower or 'between' in line_lower or 
                    'factors' in line_lower or 'effects' in line_lower):
                    title_score += 2
                
                if title_score >= 4:
                    title_candidates.append((title_score, line, i))
            
            # Return the highest scoring candidate from the top of the document
            if title_candidates:
                title_candidates.sort(key=lambda x: (-x[0], x[2]))  # Sort by score desc, position asc
                best_title = title_candidates[0][1]
                best_position = title_candidates[0][2]
                
                # Check if this might be part of a multi-line title
                # Look for a continuation on the next line
                if best_position + 1 < len(lines):
                    next_line = lines[best_position + 1].strip()
                    if (len(next_line) > 10 and 
                        not next_line.endswith('.') and
                        not any(re.search(pattern, next_line.lower()) for pattern in skip_patterns) and
                        not re.match(r'^[A-Z][a-z]+(\s+[A-Z][a-z]*\.?)?\s+[A-Z][a-z]+', next_line)):
                        # This looks like a title continuation
                        combined_title = f"{best_title} {next_line}"
                        return self._clean_title_formatting(combined_title)
                        
                return self._clean_title_formatting(best_title)
            
            # Fallback: look for the longest substantial line in first 10 lines
            for line in lines[:10]:
                if (len(line) > 30 and 
                    not any(re.search(pattern, line.lower()) for pattern in skip_patterns)):
                    return self._clean_title_formatting(line)
                    
        except Exception:
            pass
        
        return None
    
    def _clean_title_formatting(self, title: str) -> str:
        """Clean HTML/XML formatting tags and other artifacts from titles."""
        if not title:
            return title
            
        # Remove HTML/XML tags
        title = re.sub(r'<[^>]+>', '', title)
        
        # Remove common formatting artifacts
        title = re.sub(r'&[a-zA-Z]+;', '', title)  # HTML entities like &amp;
        
        # Clean up extra whitespace
        title = re.sub(r'\s+', ' ', title).strip()
        
        return title
    
    def extract_authors_from_content(self) -> List[str]:
        """Extract authors from PDF content."""
        try:
            first_page = self.plumber.pages[0]
            text = first_page.extract_text()
            
            if not text:
                return []
            
            # Common author patterns
            author_patterns = [
                r'(?:Author[s]?|By):\s*([^\n]+)',
                r'([A-Z][a-z]+ [A-Z][a-z]+(?:,\s*[A-Z][a-z]+ [A-Z][a-z]+)*)',
                r'([A-Z]\.\s*[A-Z][a-z]+(?:,\s*[A-Z]\.\s*[A-Z][a-z]+)*)',
            ]
            
            for pattern in author_patterns:
                matches = re.findall(pattern, text)
                if matches:
                    authors = []
                    for match in matches[:3]:  # Limit to first 3 matches
                        # Split multiple authors
                        author_list = re.split(r',\s*(?:and\s+)?|;\s*|\s+and\s+', match)
                        authors.extend([author.strip() for author in author_list if author.strip()])
                    return authors[:5]  # Limit to 5 authors
                    
        except Exception:
            pass
        
        return []
    
    def extract_doi_from_content(self) -> Optional[str]:
        """Extract DOI from PDF content."""
        try:
            # Check first few pages
            for page_num in range(min(3, len(self.plumber.pages))):
                page = self.plumber.pages[page_num]
                text = page.extract_text()
                
                if not text:
                    continue
                
                # DOI patterns
                doi_patterns = [
                    r'DOI:\s*(10\.\d+/[^\s]+)',
                    r'doi:\s*(10\.\d+/[^\s]+)',
                    r'https?://doi\.org/(10\.\d+/[^\s]+)',
                    r'(10\.\d{4,}/[^\s]+)',
                ]
                
                for pattern in doi_patterns:
                    match = re.search(pattern, text, re.IGNORECASE)
                    if match:
                        return match.group(1)
                        
        except Exception:
            pass
        
        return None
    
    def extract_keywords_from_content(self) -> List[str]:
        """Extract research keywords from PDF content."""
        try:
            # Check first few pages for keywords
            keywords = []
            for page_num in range(min(3, len(self.plumber.pages))):
                page = self.plumber.pages[page_num]
                text = page.extract_text()
                
                if not text:
                    continue
                
                lines = text.split('\n')
                
                # First pass: Look for explicit "Keywords" lines (Pattern 1 - high priority)
                explicit_keywords = []
                for i, line in enumerate(lines):
                    line = line.strip()
                    line_lower = line.lower()
                    
                    # Pattern 1: Direct "Keywords" line (with or without colon) or "KEYWORDS" at end of line
                    keywords_match = re.search(r'key\s*words?\s*[:;]?\s*(.*)', line_lower)
                    if keywords_match or line.upper().strip().endswith('KEYWORDS'):
                        if keywords_match:
                            keyword_text = keywords_match.group(1).strip()
                        else:
                            keyword_text = ''
                        
                        # If keywords continue on next line(s), include them
                        if not keyword_text and i + 1 < len(lines):
                            keyword_text = lines[i + 1].strip()
                        
                        # Handle multi-line keywords - look ahead for continuation
                        full_keyword_text = keyword_text
                        j = i + 1
                        while j < len(lines) and j < i + 4:  # Check up to 3 lines ahead
                            next_line = lines[j].strip()
                            if not next_line:
                                j += 1
                                continue
                            # Stop if next line looks like a new section
                            if (re.match(r'^(abstract|introduction|methods|results|background|received|accepted)', next_line.lower()) or
                                re.match(r'^\d+[A-Z][a-z]', next_line) or  # Affiliation numbers
                                'university' in next_line.lower() or 'institute' in next_line.lower()):
                                break
                            
                            # Extract keywords from mixed content lines
                            keyword_part = self._extract_keywords_from_mixed_line(next_line)
                            if keyword_part:
                                if full_keyword_text:
                                    full_keyword_text += ' ' + keyword_part
                                else:
                                    full_keyword_text = keyword_part
                                j += 1
                            # If line looks like continuation, add it
                            elif (';' in next_line or ',' in next_line or  # Has separators
                                full_keyword_text.endswith(',') or full_keyword_text.endswith(';') or 
                                full_keyword_text.endswith('\u037e') or  # Greek question mark (looks like semicolon)
                                (not next_line[0].isupper() and len(next_line) < 80)):  # Lowercase start or short line
                                full_keyword_text += ' ' + next_line
                                j += 1
                            else:
                                break
                        
                        if full_keyword_text:
                            # Split by common separators - handle semicolons, commas, pipes, and other separators
                            if ';' in full_keyword_text or '\u037e' in full_keyword_text:
                                keyword_list = re.split(r'[;\u037e]\s*', full_keyword_text)
                            elif '|' in full_keyword_text:
                                keyword_list = re.split(r'[|]\s*', full_keyword_text)  # Handle pipe separator
                            elif ',' in full_keyword_text:
                                keyword_list = re.split(r'[,]\s*', full_keyword_text)
                            elif '·' in full_keyword_text:
                                keyword_list = re.split(r'[·]\s*', full_keyword_text)  # Handle middot separator
                            else:
                                # Single keyword or space-separated
                                keyword_list = [full_keyword_text]
                            
                            for keyword in keyword_list:
                                keyword = keyword.strip().strip('.,;·')  # Strip various separators
                                
                                # Clean up concatenated compound keywords
                                keyword = self._clean_concatenated_keyword(keyword)
                                
                                if keyword and len(keyword) > 1 and len(keyword) < 100:  # Allow longer keywords
                                    explicit_keywords.append(keyword)
                            break  # Found explicit keywords, use these
                
                # If we found explicit keywords, use them; otherwise don't guess
                if explicit_keywords:
                    keywords = explicit_keywords
                # Note: Removed Pattern 2 automatic detection as it was incorrectly 
                # identifying content lines as keywords. Only use explicit keyword sections.
                
                if keywords:
                    break  # Found keywords, don't need to check more pages
            
            # Clean and deduplicate keywords
            cleaned_keywords = []
            seen = set()
            for kw in keywords:
                kw = kw.strip().strip('.')
                
                # Clean up concatenated keywords
                kw = self._clean_concatenated_keyword(kw)
                
                if (kw and len(kw) > 1 and len(kw) < 50 and 
                    kw.lower() not in seen and
                    not re.match(r'^\d+$', kw)):  # Not just numbers
                    cleaned_keywords.append(kw)
                    seen.add(kw.lower())
            
            return cleaned_keywords[:10]  # Limit to 10 keywords
                    
        except Exception:
            pass
        
        return []
    
    def is_generic_metadata(self, field_value: str, field_name: str) -> bool:
        """Check if metadata appears to be generic/incorrect."""
        if not field_value:
            return True
        
        field_lower = field_value.lower()
        
        # Generic patterns for titles
        if field_name == 'Title':
            generic_patterns = [
                'int. j. med. sci.',
                'journal',
                'bmc',
                'elsevier',
                'springer',
                'nature',
                'plos',
                'untitled',
                'document',
                'article'
            ]
            # If title is just journal name or very short
            if any(pattern in field_lower for pattern in generic_patterns) and len(field_value) < 100:
                return True
        
        # Generic patterns for authors
        if field_name == 'Author':
            generic_patterns = [
                'international journal',
                'medical sciences',
                'international publisher',
                'elsevier',
                'springer',
                'nature',
                'open access',
                'bmc',
                'plos'
            ]
            if any(pattern in field_lower for pattern in generic_patterns):
                return True
        
        return False
    
    def get_comprehensive_metadata(self) -> Dict[str, str]:
        """Get comprehensive metadata combining existing and extracted info."""
        metadata = self.get_existing_metadata()
        
        # Extract DOI first as it will be used for verification
        doi = self.extract_doi_from_content()
        
        # Extract title from content (prioritize over generic metadata)
        existing_title = metadata.get('Title', '')
        if not existing_title or self.is_generic_metadata(existing_title, 'Title'):
            title = self.extract_title_from_content()
            if title:
                metadata['Title'] = title
        
        # Extract authors from content (prioritize over generic metadata)
        existing_author = metadata.get('Author', '')
        if not existing_author or self.is_generic_metadata(existing_author, 'Author'):
            authors = self.extract_authors_from_content()
            if authors:
                # Format multiple authors for iBooks compatibility
                if len(authors) == 1:
                    metadata['Author'] = authors[0]
                elif len(authors) == 2:
                    metadata['Author'] = f"{authors[0]} and {authors[1]}"
                else:
                    # For 3+ authors, use "Author1, Author2, and Author3" format
                    all_but_last = ', '.join(authors[:-1])
                    metadata['Author'] = f"{all_but_last}, and {authors[-1]}"
        
        if not metadata.get('Subject'):
            if doi:
                metadata['Subject'] = f"DOI: {doi}"
        
        # Extract and add keywords (with deduplication and Preview.app compatibility)
        existing_keywords = metadata.get('Keywords', '')
        if not existing_keywords:
            keywords = self.extract_keywords_from_content()
            if keywords:
                metadata['Keywords'] = ', '.join(keywords)  # Always comma-separated
        else:
            # Clean up existing keywords by removing duplicates and ensuring comma separation
            metadata['Keywords'] = self._deduplicate_keywords(existing_keywords)  # Returns comma-separated
        
        # Enhance with DOI lookup if enabled and DOI available
        if self.enable_doi_lookup and doi:
            try:
                metadata = self.doi_lookup.enhance_metadata_with_doi(metadata, doi)
            except Exception:
                # Don't let DOI lookup failures break the extraction
                pass
        
        return metadata
    
    def suggest_filename(self) -> str:
        """Suggest a clean filename based on metadata."""
        metadata = self.get_comprehensive_metadata()
        
        title = metadata.get('Title', '')
        authors = metadata.get('Author', '')
        
        # Clean title for filename
        if title:
            # Remove special characters, limit length
            clean_title = re.sub(r'[^\w\s-]', '', title)
            clean_title = re.sub(r'\s+', ' ', clean_title).strip()
            if len(clean_title) > 80:
                clean_title = clean_title[:77] + '...'
        else:
            clean_title = "Unknown_Title"
        
        # Add first author if available
        if authors:
            first_author = authors.split(';')[0].split(',')[0].strip()
            first_author = re.sub(r'[^\w\s]', '', first_author)
            first_author = first_author.replace(' ', '_')
            if first_author:
                return f"{first_author} - {clean_title}.pdf"
        
        return f"{clean_title}.pdf"
    
    def _deduplicate_keywords(self, keywords_string: str) -> str:
        """Remove duplicate keywords from a comma-separated string."""
        if not keywords_string:
            return ''
        
        # Split by comma and clean up
        keywords = [kw.strip() for kw in keywords_string.split(',')]
        
        # Deduplicate case-insensitively while preserving original case
        seen = set()
        deduplicated = []
        
        for keyword in keywords:
            if keyword and keyword.lower() not in seen:
                seen.add(keyword.lower())
                deduplicated.append(keyword)
        
        return ', '.join(deduplicated)
    
    def _clean_concatenated_keyword(self, keyword: str) -> str:
        """Clean up concatenated compound keywords by adding proper spacing."""
        if not keyword or len(keyword) < 10:  # Skip short keywords
            return keyword
        
        # Dictionary of common concatenated patterns and their corrections
        concatenated_patterns = {
            'healthservicesutilisation': 'health services utilisation',
            'healthservicesutilization': 'health services utilization', 
            'residentialrehabilitation': 'residential rehabilitation',
            'substanceusedisorder': 'substance use disorder',
            'substanceusedisorders': 'substance use disorders',
            'drugusedisorders': 'drug use disorders',
            'drugusedisorder': 'drug use disorder',
            'methamphetamineuseDisorder': 'methamphetamine use disorder',
            'methamphetamineusedisorder': 'methamphetamine use disorder',
            'sexuallytransmittedinfection': 'sexually transmitted infection',
            'sexuallytransmittedinfections': 'sexually transmitted infections',
            'menwhohavesexwithmen': 'men who have sex with men',
            'gayand bisexualmen': 'gay and bisexual men',
            'gayandbisexualmen': 'gay and bisexual men',
            'hivpreventiontreatment': 'HIV prevention treatment',
            'drugenhancedsexualactivity': 'drug-enhanced sexual activity',
            'sexualiseddruguse': 'sexualised drug use',
            'sexualizeddruguse': 'sexualized drug use',
            'abusepotential': 'abuse potential',
            'psychomotorsensitization': 'psychomotor sensitization',
            'economicdemandcurve': 'economic demand curve',
            'liberaleducation': 'liberal education',
        }
        
        # Check for exact matches first (case insensitive)
        keyword_lower = keyword.lower()
        if keyword_lower in concatenated_patterns:
            return concatenated_patterns[keyword_lower]
        
        # Pattern-based splitting for common compound terms
        # Split on common word boundaries in compound terms
        import re
        
        # Handle service/services patterns
        keyword = re.sub(r'([a-z])services([a-z])', r'\1 services \2', keyword, flags=re.IGNORECASE)
        keyword = re.sub(r'([a-z])service([A-Z])', r'\1 service \2', keyword)
        
        # Handle use/usage patterns  
        keyword = re.sub(r'([a-z])use([A-Z])', r'\1 use \2', keyword)
        keyword = re.sub(r'([a-z])usage([A-Z])', r'\1 usage \2', keyword)
        
        # Handle disorder/disorders patterns
        keyword = re.sub(r'([a-z])disorders?([A-Z])', r'\1 disorder \2', keyword)
        
        # Clean up multiple spaces
        keyword = re.sub(r'\s+', ' ', keyword).strip()
        
        return keyword
    
    def _extract_keywords_from_mixed_line(self, line: str) -> str:
        """Extract keywords from a line that contains mixed content (text + keywords)."""
        # Look for patterns of comma-separated lowercase terms that could be keywords
        # Example: "ZhejiangProvince,Grant/AwardNumber: abusepotential,drugusedisorders,economicdemandcurve"
        
        # Find comma-separated sequences of lowercase words
        import re
        
        # Look for sequences like "word,word,word" (at least 2 comma-separated terms)
        keyword_pattern = r'\b([a-z]+(?:[a-z-]+[a-z])*(?:,[a-z]+(?:[a-z-]+[a-z])*)+)'
        matches = re.findall(keyword_pattern, line.lower())
        
        if matches:
            # Take the longest sequence of comma-separated terms
            longest_match = max(matches, key=len)
            # Verify it has at least 2 commas (3+ terms)
            if longest_match.count(',') >= 1:
                return longest_match
        
        return ''
    
    def close(self):
        """Close PDF resources."""
        if self._plumber:
            self._plumber.close()