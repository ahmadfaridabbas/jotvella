use base64::engine::general_purpose::STANDARD;
use base64::Engine;
use onenote_parser::contents::{Content, Image, Outline, OutlineElement, OutlineGroup, OutlineItem, RichText, Table};
use onenote_parser::page::PageContent;
use onenote_parser::{Parser, section::Section};
use serde::Serialize;
use std::io::Read;
use typed_path::TypedPath;

#[derive(Serialize)]
struct ImportedSection {
    name: String,
    pages: Vec<ImportedPage>,
}

#[derive(Serialize)]
struct ImportedPage {
    title: String,
    body: String,
    blocks: Vec<ImportedBlock>,
    images: Vec<ImportedImage>,
}

#[derive(Serialize)]
struct ImportedBlock {
    text: Option<String>,
    table: Option<Vec<Vec<String>>>,
}

#[derive(Serialize)]
struct ImportedImage {
    data: String,
    extension: String,
    x: f64,
    y: f64,
}

fn plain_text_for_element(element: &OutlineElement) -> String {
    let mut paragraphs = Vec::new();
    collect_element(element, &mut paragraphs, &mut Vec::new(), &mut Vec::new());
    paragraphs.join("\n")
}

fn collect_outline(outline: &Outline, paragraphs: &mut Vec<String>, blocks: &mut Vec<ImportedBlock>, images: &mut Vec<ImportedImage>) {
    for item in outline.items() {
        collect_item(item, paragraphs, blocks, images);
    }
}

fn collect_item(item: &OutlineItem, paragraphs: &mut Vec<String>, blocks: &mut Vec<ImportedBlock>, images: &mut Vec<ImportedImage>) {
    match item {
        OutlineItem::Group(group) => collect_group(group, paragraphs, blocks, images),
        OutlineItem::Element(element) => collect_element(element, paragraphs, blocks, images),
    }
}

fn collect_group(group: &OutlineGroup, paragraphs: &mut Vec<String>, blocks: &mut Vec<ImportedBlock>, images: &mut Vec<ImportedImage>) {
    for item in group.outlines() {
        collect_item(item, paragraphs, blocks, images);
    }
}

fn collect_element(element: &OutlineElement, paragraphs: &mut Vec<String>, blocks: &mut Vec<ImportedBlock>, images: &mut Vec<ImportedImage>) {
    for content in element.contents() {
        collect_content(content, paragraphs, blocks, images);
    }
    for item in element.children() {
        collect_item(item, paragraphs, blocks, images);
    }
}

fn collect_content(content: &Content, paragraphs: &mut Vec<String>, blocks: &mut Vec<ImportedBlock>, images: &mut Vec<ImportedImage>) {
    match content {
        Content::RichText(text) => append_rich_text(text, paragraphs, blocks),
        Content::Table(table) => append_table(table, paragraphs, blocks),
        Content::Image(image) => append_image(image, images),
        Content::EmbeddedFile(file) => {
            if !file.filename().is_empty() {
                let name = file.filename();
                paragraphs.push(format!("[Attachment: {name}]"));
            }
        }
        Content::Ink(_) => {}
        Content::Unknown => {}
    }
}

fn append_rich_text(text: &RichText, paragraphs: &mut Vec<String>, blocks: &mut Vec<ImportedBlock>) {
    let value = text.text().trim_end_matches(['\r', '\n']);
    if !value.is_empty() {
        paragraphs.push(value.to_string());
        blocks.push(ImportedBlock { text: Some(value.to_string()), table: None });
    }
}

fn append_table(table: &Table, paragraphs: &mut Vec<String>, blocks: &mut Vec<ImportedBlock>) {
    let rows = table.contents().iter().map(|row| {
        let cells = row.contents().iter().map(|cell| {
            cell.contents().iter().map(plain_text_for_element).filter(|s| !s.is_empty()).collect::<Vec<_>>().join(" ")
        }).collect::<Vec<_>>();
        cells
    }).collect::<Vec<_>>();
    for row in &rows {
        paragraphs.push(row.join("\t"));
    }
    blocks.push(ImportedBlock { text: None, table: Some(rows) });
}

fn append_image(image: &Image, images: &mut Vec<ImportedImage>) {
    let Some(mut reader) = image.read() else { return };
    let mut bytes = Vec::new();
    if reader.read_to_end(&mut bytes).is_err() || bytes.is_empty() { return }
    images.push(ImportedImage {
        data: STANDARD.encode(bytes),
        extension: image.extension().unwrap_or("png").to_string(),
        x: f64::from(image.offset_horizontal().unwrap_or(0.0)) * 36.0,
        y: f64::from(image.offset_vertical().unwrap_or(0.0)) * 36.0,
    });
}

fn convert(section: Section) -> ImportedSection {
    let mut pages = Vec::new();
    for series in section.page_series() {
        for page in series.pages() {
            let mut paragraphs = Vec::new();
            let mut blocks = Vec::new();
            let mut images = Vec::new();
            for content in page.contents() {
                match content {
                    PageContent::Outline(outline) => collect_outline(outline, &mut paragraphs, &mut blocks, &mut images),
                    PageContent::Image(image) => append_image(image, &mut images),
                    PageContent::EmbeddedFile(file) => {
                        if !file.filename().is_empty() { paragraphs.push(format!("[Attachment: {}]", file.filename())); }
                    }
                    PageContent::Ink(_) | PageContent::Unknown => {}
                }
            }
            let title = page.title_text().filter(|s| !s.trim().is_empty()).unwrap_or("Untitled").to_string();
            pages.push(ImportedPage { title, body: paragraphs.join("\n"), blocks, images });
        }
    }
    ImportedSection { name: section.display_name().to_string(), pages }
}

fn main() {
    let Some(path) = std::env::args().nth(1) else {
        eprintln!("usage: jotvella-one-importer <section.one>");
        std::process::exit(2);
    };
    let path = TypedPath::derive(&path);
    match Parser::new().parse_section(path) {
        Ok(section) => match serde_json::to_writer(std::io::stdout().lock(), &convert(section)) {
            Ok(()) => {}
            Err(error) => { eprintln!("could not serialize OneNote content: {error}"); std::process::exit(1); }
        },
        Err(error) => { eprintln!("could not read OneNote section: {error}"); std::process::exit(1); }
    }
}
