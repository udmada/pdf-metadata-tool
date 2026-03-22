"""DOI-based metadata lookup for title verification."""

import json
import re
from typing import Dict, Optional

import httpx


class DOILookup:
    """Look up metadata using DOI through CrossRef API."""
    
    def __init__(self, timeout: int = 10):
        self.timeout = timeout
        self.base_url = "https://api.crossref.org/works/"
        self.headers = {
            "User-Agent": "PDF-Metadata-Tool/1.0 (https://github.com/user/pdf-metadata-tool; mailto:contact@example.com)"
        }
    
    def clean_doi(self, doi: str) -> Optional[str]:
        """Clean and validate DOI format."""
        if not doi:
            return None
        
        # Remove common prefixes and clean up
        doi = doi.strip()
        doi = re.sub(r'^(doi:|DOI:)\s*', '', doi, flags=re.IGNORECASE)
        doi = re.sub(r'^https?://doi\.org/', '', doi)
        doi = re.sub(r'^https?://dx\.doi\.org/', '', doi)
        
        # Validate DOI format (starts with 10.)
        if not re.match(r'^10\.\d{4,}/\S+', doi):
            return None
        
        return doi
    
    def lookup_metadata(self, doi: str) -> Optional[Dict[str, str]]:
        """Look up paper metadata using DOI via CrossRef API."""
        clean_doi = self.clean_doi(doi)
        if not clean_doi:
            return None
        
        try:
            with httpx.Client(timeout=self.timeout) as client:
                url = f"{self.base_url}{clean_doi}"
                response = client.get(url, headers=self.headers)
                
                if response.status_code != 200:
                    return None
                
                data = response.json()
                work = data.get('message', {})
                
                if not work:
                    return None
                
                # Extract metadata
                metadata = {}
                
                # Title
                titles = work.get('title', [])
                if titles:
                    metadata['Title'] = titles[0]
                
                # Authors
                authors_data = work.get('author', [])
                if authors_data:
                    authors = []
                    for author in authors_data[:5]:  # Limit to 5 authors
                        given = author.get('given', '')
                        family = author.get('family', '')
                        if family:
                            if given:
                                authors.append(f"{given} {family}")
                            else:
                                authors.append(family)
                    
                    if authors:
                        if len(authors) == 1:
                            metadata['Author'] = authors[0]
                        elif len(authors) == 2:
                            metadata['Author'] = f"{authors[0]} and {authors[1]}"
                        else:
                            # For 3+ authors, use "Author1, Author2, and Author3" format
                            all_but_last = ', '.join(authors[:-1])
                            metadata['Author'] = f"{all_but_last}, and {authors[-1]}"
                
                # Journal/Publisher as Subject
                journal = work.get('container-title', [])
                if journal:
                    metadata['Subject'] = journal[0]
                
                # Publication date
                pub_date = work.get('published-print') or work.get('published-online')
                if pub_date and 'date-parts' in pub_date:
                    date_parts = pub_date['date-parts'][0]
                    if date_parts:
                        year = date_parts[0]
                        metadata['Year'] = str(year)
                
                # Keywords from subject
                subjects = work.get('subject', [])
                if subjects:
                    # Limit and clean keywords
                    keywords = [subj for subj in subjects[:10] if len(subj) > 2]
                    if keywords:
                        metadata['Keywords'] = ', '.join(keywords)
                
                # DOI
                metadata['DOI'] = clean_doi
                
                return metadata
                
        except Exception:
            # Silently fail - we don't want network issues to break the tool
            pass
        
        return None
    
    def verify_title(self, extracted_title: str, doi: str) -> Optional[str]:
        """Verify and potentially correct title using DOI lookup."""
        if not extracted_title or not doi:
            return extracted_title
        
        metadata = self.lookup_metadata(doi)
        if not metadata or 'Title' not in metadata:
            return extracted_title
        
        doi_title = metadata['Title'].strip()
        extracted_title = extracted_title.strip()
        
        # Check if extracted title looks like it's from abstract/content (contains fragments)
        problematic_patterns = [
            r'\.\s+among\s+',  # "... Among respondents"
            r'\.\s+the\s+',     # "... The study"
            r'\.\s+in\s+',      # "... In this"
            r'\.\s+this\s+',    # "... This research"
            r'\.\s+however\s+', # "... However,"
            r'\.\s+moreover\s+', # "... Moreover,"
            r'regression\.\s+', # "regression. Among"
            r'analysis\.\s+',   # "analysis. The"
            r'method\.\s+',     # "method. In"
        ]
        
        # If extracted title contains problematic patterns, prefer DOI title
        if any(re.search(pattern, extracted_title, re.IGNORECASE) for pattern in problematic_patterns):
            return doi_title
        
        # If extracted title is much shorter or looks generic, prefer DOI title
        if (len(extracted_title) < len(doi_title) * 0.7 or
            len(extracted_title) < 30):
            return doi_title
        
        # If extracted title starts with lowercase or looks like a sentence fragment
        if (extracted_title[0].islower() or 
            extracted_title.count('.') > 1 or
            len(extracted_title.split('.')) > 2):
            return doi_title
        
        # Check for similarity (basic check)
        extracted_words = set(extracted_title.lower().split())  
        doi_words = set(doi_title.lower().split())
        
        # If titles share significant overlap, keep extracted
        overlap = len(extracted_words & doi_words)
        if overlap >= min(3, len(extracted_words) // 2, len(doi_words) // 2):
            return extracted_title
        
        # If DOI title is significantly longer and more descriptive, use it
        if len(doi_title) > len(extracted_title) * 1.2:
            return doi_title
        
        # If no significant overlap and DOI title looks more like a proper title, use it
        if overlap < 2:
            return doi_title
        
        return extracted_title
    
    def enhance_metadata_with_doi(self, existing_metadata: Dict[str, str], 
                                  doi: str) -> Dict[str, str]:
        """Enhance existing metadata with DOI lookup results."""
        if not doi:
            return existing_metadata
        
        doi_metadata = self.lookup_metadata(doi)
        if not doi_metadata:
            return existing_metadata
        
        enhanced = existing_metadata.copy()
        
        # Always prefer CrossRef API title as authoritative when available
        for key, value in doi_metadata.items():
            if key == 'Title' and value:
                # Always use CrossRef title as it's the authoritative source
                enhanced[key] = value
            elif key not in enhanced or not enhanced[key]:
                # Fill in missing fields
                enhanced[key] = value
        
        return enhanced