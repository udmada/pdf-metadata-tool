"""Command line interface for PDF metadata tool."""

import sys
from pathlib import Path
from typing import List, Optional

import click
from rich.console import Console
from rich.panel import Panel
from rich.progress import Progress, TaskID
from rich.table import Table
from rich.text import Text

from .metadata_extractor import PDFMetadataExtractor
from .metadata_editor import PDFMetadataEditor
from .file_renamer import PDFFileRenamer

console = Console()


def find_pdf_files(path: Path, recursive: bool = False) -> List[Path]:
    """Find PDF files in a directory."""
    if path.is_file() and path.suffix.lower() == '.pdf':
        return [path]
    
    if not path.is_dir():
        return []
    
    pattern = "**/*.pdf" if recursive else "*.pdf"
    return list(path.glob(pattern))


def display_metadata_preview(pdf_path: Path, metadata: dict, rename_preview: dict):
    """Display a preview of metadata and rename changes."""
    console.print(f"\n[bold blue]File:[/bold blue] {pdf_path.name}")
    
    # Metadata table
    table = Table(title="Extracted Metadata", show_header=True)
    table.add_column("Field", style="cyan", min_width=12)
    table.add_column("Value", style="green")
    
    for key, value in metadata.items():
        if value:
            # Truncate long values for display
            display_value = value[:100] + "..." if len(value) > 100 else value
            table.add_row(key, display_value)
    
    console.print(table)
    
    # Rename preview
    if rename_preview['needs_rename']:
        rename_table = Table(title="Rename Preview", show_header=True)
        rename_table.add_column("Type", style="cyan")
        rename_table.add_column("Filename", style="yellow")
        
        rename_table.add_row("Current", rename_preview['current_name'])
        rename_table.add_row("Suggested", rename_preview['final_name'])
        
        if rename_preview['conflict_detected']:
            rename_table.add_row("Note", "[red]Conflict detected - using numbered version[/red]")
        
        console.print(rename_table)
    else:
        console.print("[green]No rename needed - filename is already appropriate[/green]")


@click.group()
@click.version_option()
def cli():
    """PDF Metadata Tool - Extract, fix, and rename PDFs with proper metadata."""
    pass


@cli.command()
@click.argument('path', type=click.Path(exists=True, path_type=Path))
@click.option('--recursive', '-r', is_flag=True, help='Process directories recursively')
@click.option('--output-format', type=click.Choice(['table', 'json']), default='table', 
              help='Output format for metadata display')
@click.option('--no-doi-lookup', is_flag=True, help='Disable DOI-based metadata lookup')
def extract(path: Path, recursive: bool, output_format: str, no_doi_lookup: bool):
    """Extract and display metadata from PDF files."""
    pdf_files = find_pdf_files(path, recursive)
    
    if not pdf_files:
        console.print("[red]No PDF files found.[/red]")
        return
    
    console.print(f"[blue]Found {len(pdf_files)} PDF file(s)[/blue]")
    
    for pdf_file in pdf_files:
        try:
            extractor = PDFMetadataExtractor(pdf_file, enable_doi_lookup=not no_doi_lookup)
            metadata = extractor.get_comprehensive_metadata()
            extractor.close()
            
            if output_format == 'table':
                display_metadata_preview(pdf_file, metadata, {'needs_rename': False})
            else:
                # JSON output
                import json
                result = {
                    'file': str(pdf_file),
                    'metadata': metadata
                }
                console.print(json.dumps(result, indent=2))
                
        except Exception as e:
            console.print(f"[red]Error processing {pdf_file.name}: {e}[/red]")


@cli.command()
@click.argument('path', type=click.Path(exists=True, path_type=Path))
@click.option('--recursive', '-r', is_flag=True, help='Process directories recursively')
@click.option('--dry-run', is_flag=True, help='Preview changes without applying them')
@click.option('--backup/--no-backup', default=True, help='Create backups before modifying files')
@click.option('--no-doi-lookup', is_flag=True, help='Disable DOI-based metadata lookup')
def rename(path: Path, recursive: bool, dry_run: bool, backup: bool, no_doi_lookup: bool):
    """Rename PDF files based on their metadata."""
    pdf_files = find_pdf_files(path, recursive)
    
    if not pdf_files:
        console.print("[red]No PDF files found.[/red]")
        return
    
    console.print(f"[blue]Processing {len(pdf_files)} PDF file(s)[/blue]")
    renamer = PDFFileRenamer()
    renamed_count = 0
    
    with Progress() as progress:
        task = progress.add_task("Processing files...", total=len(pdf_files))
        
        for pdf_file in pdf_files:
            try:
                # Extract metadata
                extractor = PDFMetadataExtractor(pdf_file, enable_doi_lookup=not no_doi_lookup)
                metadata = extractor.get_comprehensive_metadata()
                extractor.close()
                
                # Get rename preview
                rename_preview = renamer.preview_rename(pdf_file, metadata)
                
                if rename_preview['needs_rename']:
                    if dry_run:
                        console.print(f"\n[yellow]Would rename:[/yellow] {pdf_file.name}")
                        console.print(f"[yellow]To:[/yellow] {rename_preview['final_name']}")
                    else:
                        new_path = Path(rename_preview['final_path'])
                        renamer.rename_file(pdf_file, new_path)
                        console.print(f"[green]Renamed:[/green] {pdf_file.name} → {new_path.name}")
                        renamed_count += 1
                else:
                    console.print(f"[dim]No rename needed:[/dim] {pdf_file.name}")
                
                progress.advance(task)
                
            except Exception as e:
                console.print(f"[red]Error processing {pdf_file.name}: {e}[/red]")
                progress.advance(task)
    
    if dry_run:
        console.print(f"\n[blue]Dry run completed. Would rename {renamed_count} files.[/blue]")
    else:
        console.print(f"\n[green]Renamed {renamed_count} files successfully.[/green]")


@cli.command()
@click.argument('path', type=click.Path(exists=True, path_type=Path))
@click.option('--recursive', '-r', is_flag=True, help='Process directories recursively')
@click.option('--dry-run', is_flag=True, help='Preview changes without applying them')
@click.option('--backup/--no-backup', default=True, help='Create backups before modifying files')
@click.option('--no-doi-lookup', is_flag=True, help='Disable DOI-based metadata lookup')
@click.option('--force', is_flag=True, help='Force re-extract and update all metadata, even if no changes detected')
def fix_metadata(path: Path, recursive: bool, dry_run: bool, backup: bool, no_doi_lookup: bool, force: bool):
    """Fix and enhance PDF metadata."""
    pdf_files = find_pdf_files(path, recursive)
    
    if not pdf_files:
        console.print("[red]No PDF files found.[/red]")
        return
    
    console.print(f"[blue]Processing {len(pdf_files)} PDF file(s)[/blue]")
    fixed_count = 0
    
    with Progress() as progress:
        task = progress.add_task("Fixing metadata...", total=len(pdf_files))
        
        for pdf_file in pdf_files:
            try:
                # Extract comprehensive metadata
                extractor = PDFMetadataExtractor(pdf_file, enable_doi_lookup=not no_doi_lookup)
                existing_metadata = extractor.get_existing_metadata()
                comprehensive_metadata = extractor.get_comprehensive_metadata()
                extractor.close()
                
                # Check if metadata needs enhancement (or force update)
                needs_update = force  # Force update if --force flag is used
                if not force:
                    for key in ['Title', 'Author', 'Subject', 'Keywords']:
                        if key not in existing_metadata and key in comprehensive_metadata:
                            needs_update = True
                            break
                
                if needs_update:
                    if dry_run:
                        console.print(f"\n[yellow]Would update metadata for:[/yellow] {pdf_file.name}")
                        if force:
                            console.print(f"  [yellow]Force update all metadata fields[/yellow]")
                        for key, value in comprehensive_metadata.items():
                            if (force or key not in existing_metadata) and value:
                                status = "Update" if key in existing_metadata else "Add"
                                console.print(f"  [yellow]{status} {key}:[/yellow] {value[:60]}...")
                        fixed_count += 1  # Count for dry run summary
                    else:
                        editor = PDFMetadataEditor(pdf_file)
                        if backup:
                            editor.create_backup()
                        editor.enhance_metadata(comprehensive_metadata)
                        console.print(f"[green]Updated metadata:[/green] {pdf_file.name}")
                        fixed_count += 1
                else:
                    console.print(f"[dim]Metadata OK:[/dim] {pdf_file.name}")
                
                progress.advance(task)
                
            except Exception as e:
                console.print(f"[red]Error processing {pdf_file.name}: {e}[/red]")
                progress.advance(task)
    
    if dry_run:
        console.print(f"\n[blue]Dry run completed. Would update {fixed_count} files.[/blue]")
    else:
        console.print(f"\n[green]Updated metadata for {fixed_count} files.[/green]")


@cli.command()
@click.argument('path', type=click.Path(exists=True, path_type=Path))
@click.option('--recursive', '-r', is_flag=True, help='Process directories recursively')
@click.option('--dry-run', is_flag=True, help='Preview changes without applying them')
@click.option('--backup/--no-backup', default=True, help='Create backups before modifying files')
@click.option('--no-doi-lookup', is_flag=True, help='Disable DOI-based metadata lookup')
@click.option('--force', is_flag=True, help='Force re-extract and update all metadata, even if no changes detected')
def process_all(path: Path, recursive: bool, dry_run: bool, backup: bool, no_doi_lookup: bool, force: bool):
    """Process all PDFs: fix metadata and rename files."""
    pdf_files = find_pdf_files(path, recursive)
    
    if not pdf_files:
        console.print("[red]No PDF files found.[/red]")
        return
    
    console.print(Panel.fit(
        f"[bold blue]PDF Metadata Tool[/bold blue]\n"
        f"Processing {len(pdf_files)} PDF files\n"
        f"Mode: {'DRY RUN' if dry_run else 'LIVE'}\n"
        f"Backups: {'Enabled' if backup and not dry_run else 'Disabled'}\n"
        f"DOI Lookup: {'Disabled' if no_doi_lookup else 'Enabled'}\n"
        f"Force Update: {'Enabled' if force else 'Disabled'}"
    ))
    
    renamer = PDFFileRenamer()
    fixed_count = 0
    renamed_count = 0
    
    with Progress() as progress:
        task = progress.add_task("Processing files...", total=len(pdf_files))
        
        for pdf_file in pdf_files:
            try:
                console.print(f"\n[bold]Processing:[/bold] {pdf_file.name}")
                
                # Extract metadata
                extractor = PDFMetadataExtractor(pdf_file, enable_doi_lookup=not no_doi_lookup)
                existing_metadata = extractor.get_existing_metadata()
                comprehensive_metadata = extractor.get_comprehensive_metadata()
                extractor.close()
                
                # Display preview
                rename_preview = renamer.preview_rename(pdf_file, comprehensive_metadata)
                display_metadata_preview(pdf_file, comprehensive_metadata, rename_preview)
                
                # Count what would be done in dry run
                needs_metadata_update = force  # Force update if --force flag is used
                if not force:
                    needs_metadata_update = any(
                        key not in existing_metadata and key in comprehensive_metadata
                        for key in ['Title', 'Author', 'Subject', 'Keywords']
                    )
                
                if needs_metadata_update:
                    if dry_run:
                        fixed_count += 1
                    else:
                        editor = PDFMetadataEditor(pdf_file)
                        if backup:
                            editor.create_backup()
                        editor.enhance_metadata(comprehensive_metadata)
                        console.print("[green]✓ Metadata updated[/green]")
                        fixed_count += 1
                
                # Handle renaming
                if rename_preview['needs_rename']:
                    if dry_run:
                        renamed_count += 1
                    else:
                        new_path = Path(rename_preview['final_path'])
                        final_path = renamer.rename_file(pdf_file, new_path)
                        console.print(f"[green]✓ Renamed to:[/green] {final_path.name}")
                        renamed_count += 1
                
                progress.advance(task)
                
            except Exception as e:
                console.print(f"[red]✗ Error: {e}[/red]")
                progress.advance(task)
    
    # Summary
    if dry_run:
        console.print(Panel.fit(
            f"[bold blue]Dry Run Summary[/bold blue]\n"
            f"Would update metadata: {fixed_count} files\n"
            f"Would rename: {renamed_count} files"
        ))
    else:
        console.print(Panel.fit(
            f"[bold green]Processing Complete[/bold green]\n"
            f"Metadata updated: {fixed_count} files\n"
            f"Files renamed: {renamed_count} files"
        ))


if __name__ == '__main__':
    cli()