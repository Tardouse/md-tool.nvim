use std::collections::HashMap;
use std::path::{Path, PathBuf};

use pulldown_cmark::{html, CowStr, Event, Options, Parser, Tag, TagEnd};

const LOCAL_FILE_ROUTE_PREFIX: &str = "/__md_tool/file/";

pub fn render(markdown: &str, base_dir: Option<&Path>) -> String {
    let mut options = Options::empty();
    options.insert(Options::ENABLE_STRIKETHROUGH);
    options.insert(Options::ENABLE_TABLES);
    options.insert(Options::ENABLE_TASKLISTS);
    options.insert(Options::ENABLE_FOOTNOTES);
    options.insert(Options::ENABLE_SMART_PUNCTUATION);
    options.insert(Options::ENABLE_MATH);

    let parser = Parser::new_ext(markdown, options).map(|event| rewrite_event(event, base_dir));
    let mut events: Vec<Event<'_>> = parser.collect();
    add_heading_ids(&mut events);

    let mut html_output = String::with_capacity(markdown.len().saturating_add(markdown.len() / 2));
    html::push_html(&mut html_output, events.into_iter());
    html_output
}

/// Build an anchor slug matching the plugin's TOC generator (`lua/md-tool/toc.lua`):
/// lowercase, drop everything that is not ASCII alphanumeric / whitespace / hyphen,
/// then turn whitespace into hyphens. Keeping this in sync ensures `:MdTool toc`
/// links resolve against the headings rendered in the preview.
fn slugify(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    for ch in text.chars() {
        if ch.is_ascii_whitespace() {
            out.push('-');
        } else if ch.is_ascii_alphanumeric() {
            out.push(ch.to_ascii_lowercase());
        } else if ch == '-' {
            out.push('-');
        }
        // any other character (punctuation, non-ASCII, ...) is dropped
    }
    out
}

/// Assign `id` attributes to headings so in-document anchor links (e.g. a table
/// of contents) can jump to them. Duplicate slugs get `-1`, `-2`, ... suffixes,
/// matching both GitHub and the plugin's own TOC numbering.
fn add_heading_ids(events: &mut [Event<'_>]) {
    let mut seen: HashMap<String, u32> = HashMap::new();

    for i in 0..events.len() {
        let needs_id = matches!(
            &events[i],
            Event::Start(Tag::Heading { id, .. }) if id.is_none()
        );
        if !needs_id {
            continue;
        }

        let mut text = String::new();
        for event in &events[i + 1..] {
            match event {
                Event::End(TagEnd::Heading(_)) => break,
                Event::Text(t) | Event::Code(t) => text.push_str(t),
                _ => {}
            }
        }

        let base = slugify(&text);
        if base.is_empty() {
            continue;
        }

        let count = seen.entry(base.clone()).or_insert(0);
        let anchor = if *count > 0 {
            format!("{base}-{count}")
        } else {
            base.clone()
        };
        *count += 1;

        if let Event::Start(Tag::Heading { id, .. }) = &mut events[i] {
            *id = Some(CowStr::from(anchor));
        }
    }
}

fn rewrite_event<'a>(event: Event<'a>, base_dir: Option<&Path>) -> Event<'a> {
    match event {
        Event::Start(Tag::Image {
            link_type,
            dest_url,
            title,
            id,
        }) => Event::Start(Tag::Image {
            link_type,
            dest_url: rewrite_image_dest_url(dest_url, base_dir),
            title,
            id,
        }),
        other => other,
    }
}

fn rewrite_image_dest_url(dest_url: CowStr<'_>, base_dir: Option<&Path>) -> CowStr<'static> {
    let destination = dest_url.into_string();
    let Some((path, suffix)) = resolve_local_image_path(&destination, base_dir) else {
        return CowStr::from(destination);
    };

    let encoded = hex_encode(path.to_string_lossy().as_bytes());
    CowStr::from(format!("{LOCAL_FILE_ROUTE_PREFIX}{encoded}{suffix}"))
}

fn resolve_local_image_path<'a>(
    destination: &'a str,
    base_dir: Option<&Path>,
) -> Option<(PathBuf, &'a str)> {
    let trimmed = destination.trim();
    if trimmed.is_empty() || trimmed.starts_with("//") {
        return None;
    }

    let (path_part, suffix) = split_suffix(trimmed);
    if path_part.is_empty() {
        return None;
    }

    if let Some(path) = file_uri_to_path(path_part) {
        return Some((path, suffix));
    }

    if has_non_file_scheme(path_part) {
        return None;
    }

    if is_windows_absolute(path_part) || Path::new(path_part).is_absolute() {
        return Some((PathBuf::from(path_part), suffix));
    }

    base_dir.map(|dir| (dir.join(path_part), suffix))
}

fn split_suffix(value: &str) -> (&str, &str) {
    let mut suffix_index = value.len();

    if let Some(index) = value.find('#') {
        suffix_index = suffix_index.min(index);
    }
    if let Some(index) = value.find('?') {
        suffix_index = suffix_index.min(index);
    }

    value.split_at(suffix_index)
}

fn file_uri_to_path(value: &str) -> Option<PathBuf> {
    let rest = value.strip_prefix("file://")?;
    let without_authority = rest.strip_prefix("localhost/").unwrap_or(rest);
    let decoded = percent_decode(without_authority);

    #[cfg(windows)]
    let normalized = decoded
        .strip_prefix('/')
        .filter(|path| is_windows_absolute(path))
        .unwrap_or(decoded.as_str());

    #[cfg(not(windows))]
    let normalized = decoded.as_str();

    Some(PathBuf::from(normalized))
}

fn percent_decode(value: &str) -> String {
    let mut result = String::with_capacity(value.len());
    let bytes = value.as_bytes();
    let mut index = 0;

    while index < bytes.len() {
        if bytes[index] == b'%' && index + 2 < bytes.len() {
            let upper = bytes[index + 1] as char;
            let lower = bytes[index + 2] as char;
            if let (Some(left), Some(right)) = (upper.to_digit(16), lower.to_digit(16)) {
                result.push((left * 16 + right) as u8 as char);
                index += 3;
                continue;
            }
        }

        result.push(bytes[index] as char);
        index += 1;
    }

    result
}

fn has_non_file_scheme(value: &str) -> bool {
    let Some(index) = value.find(':') else {
        return false;
    };

    let scheme = &value[..index];
    if scheme.len() == 1 && scheme.chars().all(|ch| ch.is_ascii_alphabetic()) {
        return false;
    }

    !scheme.is_empty()
        && scheme
            .chars()
            .all(|ch| ch.is_ascii_alphanumeric() || matches!(ch, '+' | '-' | '.'))
}

fn is_windows_absolute(value: &str) -> bool {
    let bytes = value.as_bytes();
    bytes.len() >= 3
        && bytes[0].is_ascii_alphabetic()
        && bytes[1] == b':'
        && matches!(bytes[2], b'\\' | b'/')
}

fn hex_encode(bytes: &[u8]) -> String {
    let mut encoded = String::with_capacity(bytes.len() * 2);
    for byte in bytes {
        encoded.push(char::from_digit((byte >> 4) as u32, 16).expect("valid hex"));
        encoded.push(char::from_digit((byte & 0x0f) as u32, 16).expect("valid hex"));
    }
    encoded
}

#[cfg(test)]
mod tests {
    use super::{hex_encode, render};
    use std::path::Path;

    #[test]
    fn rewrites_relative_local_image_paths() {
        let html = render(
            "![alt](<./images/test image.png>)",
            Some(Path::new("/tmp/project")),
        );
        let expected = format!(
            "src=\"/__md_tool/file/{}\"",
            hex_encode(b"/tmp/project/./images/test image.png")
        );
        assert!(html.contains(&expected), "{html}");
    }

    #[test]
    fn keeps_remote_image_paths_unchanged() {
        let html = render(
            "![alt](https://example.com/test.png)",
            Some(Path::new("/tmp/project")),
        );
        assert!(
            html.contains("src=\"https://example.com/test.png\""),
            "{html}"
        );
    }

    #[test]
    fn adds_heading_ids_matching_toc_slugs() {
        let html = render("## 1. FPLIER: Federated Pathway-Level Information Extractor", None);
        assert!(
            html.contains(r#"<h2 id="1-fplier-federated-pathway-level-information-extractor">"#),
            "{html}"
        );
    }

    #[test]
    fn deduplicates_heading_ids() {
        let html = render("# Intro\n\n# Intro\n\n# Intro", None);
        assert!(html.contains(r#"<h1 id="intro">"#), "{html}");
        assert!(html.contains(r#"<h1 id="intro-1">"#), "{html}");
        assert!(html.contains(r#"<h1 id="intro-2">"#), "{html}");
    }

    #[test]
    fn rewrites_reference_style_images() {
        let markdown = "![alt][img]\n\n[img]: assets/pic.png";
        let html = render(markdown, Some(Path::new("/tmp/project")));
        let expected = format!(
            "src=\"/__md_tool/file/{}\"",
            hex_encode(b"/tmp/project/assets/pic.png")
        );
        assert!(html.contains(&expected), "{html}");
    }
}
