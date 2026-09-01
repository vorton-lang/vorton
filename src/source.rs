use serde::Serialize;

#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize)]
#[serde(transparent)]
pub struct SourceId(pub u32);

#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize)]
pub struct Span {
    pub source: SourceId,
    pub start: u32,
    pub end: u32,
}

impl Span {
    pub fn new(source: SourceId, start: usize, end: usize) -> Self {
        debug_assert!(start <= end);
        Self {
            source,
            start: u32::try_from(start).expect("source offset exceeds u32"),
            end: u32::try_from(end).expect("source offset exceeds u32"),
        }
    }

    pub fn join(self, other: Self) -> Self {
        debug_assert_eq!(self.source, other.source);
        Self {
            source: self.source,
            start: self.start.min(other.start),
            end: self.end.max(other.end),
        }
    }

    pub fn is_empty(self) -> bool {
        self.start == self.end
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct SourceFile {
    id: SourceId,
    path: String,
    text: String,
    line_starts: Vec<u32>,
}

impl SourceFile {
    pub fn new(
        id: SourceId,
        path: impl Into<String>,
        text: impl Into<String>,
    ) -> Result<Self, String> {
        let path = path.into();
        let text = text.into();
        if text.len() > u32::MAX as usize {
            return Err(format!(
                "source file is larger than {} bytes: {path}",
                u32::MAX
            ));
        }

        let mut line_starts = vec![0];
        for (offset, byte) in text.bytes().enumerate() {
            if byte == b'\n' {
                line_starts.push(u32::try_from(offset + 1).expect("checked source length"));
            }
        }

        Ok(Self {
            id,
            path,
            text,
            line_starts,
        })
    }

    pub fn id(&self) -> SourceId {
        self.id
    }

    pub fn path(&self) -> &str {
        &self.path
    }

    pub fn text(&self) -> &str {
        &self.text
    }

    pub fn len(&self) -> usize {
        self.text.len()
    }

    pub fn span(&self, start: usize, end: usize) -> Span {
        Span::new(self.id, start, end)
    }

    pub fn eof_span(&self) -> Span {
        self.span(self.len(), self.len())
    }

    pub fn line_index(&self, offset: u32) -> usize {
        self.line_starts
            .partition_point(|start| *start <= offset)
            .saturating_sub(1)
    }

    pub fn line_column(&self, offset: u32) -> (u32, u32) {
        let offset = offset.min(u32::try_from(self.text.len()).expect("checked source length"));
        let line_index = self.line_index(offset);
        let line_start = self.line_starts[line_index] as usize;
        let offset = offset as usize;
        let column = self.text[line_start..offset].chars().count();
        (
            u32::try_from(line_index + 1).expect("line index exceeds u32"),
            u32::try_from(column).expect("column exceeds u32"),
        )
    }

    pub fn line_text(&self, one_based_line: u32) -> Option<&str> {
        let line_index = usize::try_from(one_based_line.checked_sub(1)?).ok()?;
        let start = *self.line_starts.get(line_index)? as usize;
        let end = self
            .line_starts
            .get(line_index + 1)
            .map_or(self.text.len(), |next| *next as usize);
        Some(self.text[start..end].trim_end_matches(['\r', '\n']))
    }
}
