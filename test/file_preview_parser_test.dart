import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:parallax/features/file_preview/bounded_zip.dart';
import 'package:parallax/features/file_preview/document_loader.dart';
import 'package:parallax/features/file_preview/document_model.dart';
import 'package:parallax/features/file_preview/document_parser.dart';
import 'package:parallax/features/file_preview/office_parser.dart';

import 'file_preview_support.dart';

Uint8List fixture(String name) =>
    File('test/fixtures/file_preview/$name').readAsBytesSync();

DocumentPreview? parse(
  List<int> bytes,
  String name, {
  DocumentLimits limits = DocumentLimits.full,
}) => parseDocument(
  DocumentRequest(
    bytes: Uint8List.fromList(bytes),
    format: documentFormatFor(name, null)!,
    name: name,
    limits: limits,
  ),
);

String plain(DocBlock block) => switch (block) {
  HeadingBlock(:final level, :final spans) => 'h$level ${spansText(spans)}',
  ParagraphBlock(:final spans) => 'p ${spansText(spans)}',
  ListItemBlock(:final spans, :final depth, :final marker) =>
    'li$depth $marker ${spansText(spans)}',
  QuoteBlock(:final spans) => 'quote ${spansText(spans)}',
  CodeBlock(:final text) => 'code $text',
  TableBlock(:final rows) => 'table ${rows.map((r) => r.join('|')).join('/')}',
  RuleBlock() => 'rule',
  SlideBlock(:final number) => 'slide $number',
};

void main() {
  group('format detection', () {
    test('the extension decides, whatever the MIME type says', () {
      expect(
        documentFormatFor('Notes.MD', 'application/octet-stream'),
        DocumentFormat.markdown,
      );
      expect(documentFormatFor('a.csv', null), DocumentFormat.delimited);
      expect(documentFormatFor('a.tsv', null), DocumentFormat.delimited);
      expect(documentFormatFor('a.docx', null), DocumentFormat.word);
      expect(documentFormatFor('a.xlsx', null), DocumentFormat.spreadsheet);
      expect(documentFormatFor('a.pptx', null), DocumentFormat.slides);
      expect(documentFormatFor('server.log', null), DocumentFormat.text);
      expect(documentFormatFor('Dockerfile', null), DocumentFormat.text);
    });

    test('the MIME type decides when the name has no known extension', () {
      expect(documentFormatFor('export', 'text/csv'), DocumentFormat.delimited);
      expect(
        documentFormatFor('file', 'text/plain; charset=utf-8'),
        DocumentFormat.text,
      );
      expect(
        documentFormatFor(
          'report',
          'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
        ),
        DocumentFormat.word,
      );
      expect(
        documentFormatFor('data', 'application/json'),
        DocumentFormat.text,
      );
    });

    test('PDFs are known by extension or type, and are not parsed here', () {
      expect(documentFormatFor('a.pdf', null), DocumentFormat.pdf);
      expect(
        documentFormatFor('A.PDF', 'application/octet-stream'),
        DocumentFormat.pdf,
      );
      expect(documentFormatFor('scan', 'application/pdf'), DocumentFormat.pdf);
      // Pages are drawn by the platform (pdf_tools.dart), not read as text.
      expect(
        parseDocument(
          DocumentRequest(
            bytes: Uint8List.fromList('%PDF-1.4'.codeUnits),
            format: DocumentFormat.pdf,
            name: 'a.pdf',
          ),
        ),
        isNull,
      );
    });

    test('files it cannot read are left to the file card', () {
      expect(documentFormatFor('a.doc', 'application/msword'), isNull);
      expect(documentFormatFor('a.xls', 'application/vnd.ms-excel'), isNull);
      expect(documentFormatFor('a.zip', 'application/zip'), isNull);
      expect(documentFormatFor('photo.jpg', 'image/jpeg'), isNull);
      expect(documentFormatFor('file', null), isNull);
    });
  });

  group('text', () {
    test('UTF-8, with or without a byte-order mark', () {
      final text =
          (parse(utf8.encode('héllo\r\nwörld'), 'a.log') as TextPreview).text;
      expect(text, 'héllo\nwörld');
      expect(
        (parse([0xEF, 0xBB, 0xBF, ...utf8.encode('bom')], 'a.txt')
                as TextPreview)
            .text,
        'bom',
      );
    });

    test('UTF-16 by byte-order mark, Latin-1 as a fallback', () {
      expect(
        (parse([0xFF, 0xFE, 0x68, 0x00, 0x69, 0x00], 'a.txt') as TextPreview)
            .text,
        'hi',
      );
      expect(
        (parse([0xFE, 0xFF, 0x00, 0x68, 0x00, 0x69], 'a.txt') as TextPreview)
            .text,
        'hi',
      );
      expect(
        (parse([0x63, 0x61, 0x66, 0xE9], 'a.txt') as TextPreview).text,
        'café',
      );
    });

    test('binary data under a text name is refused', () {
      expect(
        parse([0x50, 0x4B, 0x03, 0x04, 0x00, 0x00, 0x01], 'a.txt'),
        isNull,
      );
    });

    test('long files are cut at the limit without splitting a character', () {
      final preview =
          parse(utf8.encode('é' * 5000), 'a.txt', limits: DocumentLimits.inline)
              as TextPreview;
      expect(preview.truncated, isTrue);
      expect(preview.text.length, DocumentLimits.inline.chars);
      expect(preview.text.replaceAll('é', ''), isEmpty);
    });

    test('prose uses the app font, code and logs a fixed-width one', () {
      expect(
        (parse(utf8.encode('x'), 'a.txt') as TextPreview).monospace,
        false,
      );
      expect((parse(utf8.encode('x'), 'a.py') as TextPreview).monospace, true);
    });

    test('one-line JSON is indented; other JSON is left alone', () {
      expect(
        (parse(utf8.encode('{"a":[1,2],"b":"c"}'), 'a.json') as TextPreview)
            .text,
        '{\n  "a": [\n    1,\n    2\n  ],\n  "b": "c"\n}',
      );
      expect(
        (parse(utf8.encode('{broken'), 'a.json') as TextPreview).text,
        '{broken',
      );
    });
  });

  group('CSV', () {
    List<List<String>> rows(String text, [String name = 'a.csv']) =>
        (parse(utf8.encode(text), name) as SheetPreview).sheets.single.rows;

    test('quoted fields keep commas, quotes and line breaks', () {
      expect(rows('name,note\n"Russell, Sam","said ""hi""\nthen left"\n'), [
        ['name', 'note'],
        ['Russell, Sam', 'said "hi"\nthen left'],
      ]);
    });

    test('a last row without a line break is kept; empty fields too', () {
      expect(rows('a,,c\n1,2,'), [
        ['a', '', 'c'],
        ['1', '2', ''],
      ]);
    });

    test('semicolons, tabs and pipes are detected', () {
      expect(rows('a;b\n1,5;2,5'), [
        ['a', 'b'],
        ['1,5', '2,5'],
      ]);
      expect(rows('a\tb\n1\t2', 'a.tsv'), [
        ['a', 'b'],
        ['1', '2'],
      ]);
      expect(sniffDelimiter('a|b|c\n1|2|3'), '|');
      expect(sniffDelimiter('"a;b;c;d",x\n1,2'), ',');
    });

    test('rows and columns stop at the limits', () {
      final wide = List.filled(100, 'x').join(',');
      final text = List.filled(50, wide).join('\n');
      final preview =
          parse(utf8.encode(text), 'a.csv', limits: DocumentLimits.inline)
              as SheetPreview;
      final sheet = preview.sheets.single;
      expect(preview.truncated, isTrue);
      expect(sheet.rows.length, lessThanOrEqualTo(DocumentLimits.inline.rows));
      expect(sheet.columnCount, DocumentLimits.inline.columns);
    });
  });

  group('Markdown', () {
    List<String> blocks(String text) => [
      for (final block
          in (parse(utf8.encode(text), 'a.md') as RichPreview).blocks)
        plain(block),
    ];

    test('headings, paragraphs, rules, quotes and code', () {
      expect(
        blocks(
          '# Title\n\nSome *text* here.\n\n---\n\n> quoted\n\n'
          '```dart\nfinal a = 1;\n```\n',
        ),
        [
          'h1 Title',
          'p Some text here.',
          'rule',
          'quote quoted',
          'code final a = 1;',
        ],
      );
    });

    test('lists keep their nesting, numbers and task boxes', () {
      expect(
        blocks(
          '- one\n  - inner\n- two\n\n3. three\n4. four\n\n'
          '- [x] done\n- [ ] todo\n',
        ),
        [
          'li0 • one',
          'li1 • inner',
          'li0 • two',
          'li0 3. three',
          'li0 4. four',
          'li0 ☑ done',
          'li0 ☐ todo',
        ],
      );
    });

    test('tables become rows with a header', () {
      final preview =
          parse(utf8.encode('| a | b |\n|---|---|\n| 1 | 2 |\n'), 'a.md')
              as RichPreview;
      final table = preview.blocks.single as TableBlock;
      expect(table.header, isTrue);
      expect(table.rows, [
        ['a', 'b'],
        ['1', '2'],
      ]);
    });

    test('inline styles and links are kept as spans', () {
      final preview =
          parse(
                utf8.encode(
                  '**bold** _it_ ~~gone~~ `code` [site](https://x.y)',
                ),
                'a.md',
              )
              as RichPreview;
      final spans = (preview.blocks.single as ParagraphBlock).spans;
      DocSpan span(String text) => spans.firstWhere((s) => s.text == text);
      expect(span('bold').bold, isTrue);
      expect(span('it').italic, isTrue);
      expect(span('gone').strike, isTrue);
      expect(span('code').code, isTrue);
      expect(span('site').link, 'https://x.y');
    });

    test('raw HTML is shown as text, never interpreted', () {
      expect(blocks('<script>alert(1)</script>\n'), [
        'p <script>alert(1)</script>',
      ]);
    });
  });

  group('ZIP container', () {
    test('reads stored and deflated parts', () {
      final zip = BoundedZip.parse(
        buildZip({'a.txt': 'hello', 'dir/b.txt': 'x' * 5000}, store: {'a.txt'}),
      );
      expect(zip.names, ['a.txt', 'dir/b.txt']);
      expect(zip.readText('a.txt', maxBytes: 100)!.text, 'hello');
      expect(zip.readText('dir/b.txt', maxBytes: 10000)!.text, 'x' * 5000);
      expect(zip.read('missing', maxBytes: 10), isNull);
    });

    test(
      'a part that inflates far past the limit is cut off, not expanded',
      () {
        // 64 MB of zeros deflates to about 64 KB.
        final bomb = buildZip({'bomb.xml': Uint8List(64 * 1024 * 1024)});
        expect(bomb.length, lessThan(200 * 1024));
        final part = BoundedZip.parse(bomb).read('bomb.xml', maxBytes: 1024)!;
        expect(part.truncated, isTrue);
        expect(part.bytes.length, 1024);
      },
    );

    test('damaged and unsupported archives are refused', () {
      expect(
        () => BoundedZip.parse(Uint8List.fromList(utf8.encode('not a zip'))),
        throwsFormatException,
      );
      final zip = buildZip({'a.txt': 'x' * 2000});
      // Corrupt the deflate stream (after the 30-byte header and the name).
      final broken = Uint8List.fromList(zip)..fillRange(36, 46, 0xFF);
      expect(
        () => BoundedZip.parse(broken).read('a.txt', maxBytes: 10000),
        throwsFormatException,
      );
      expect(parse(broken, 'a.docx'), isNull);
      expect(parse(utf8.encode('not a zip'), 'a.xlsx'), isNull);
    });
  });

  group('Word', () {
    test('a real .docx: headings, styled runs, lists and a table', () {
      final preview =
          parse(fixture('report.docx'), 'report.docx') as RichPreview;
      expect(preview.truncated, isFalse);
      expect(preview.blocks.map(plain), [
        'h1 Quarterly report',
        'h1 Summary',
        'p Revenue grew 12% against a flat market, see appendix.',
        'li0 • Hire two engineers',
        'li0 • Open the Perth office',
        'li0 1. Draft the plan',
        'li0 2. Review with finance',
        'h2 Figures',
        'table Region|Q1|Q2/East|10|12/West|7|9',
        'p Tom & Jerry <done> "quoted" café',
      ]);
      final spans = (preview.blocks[2] as ParagraphBlock).spans;
      expect(spans.firstWhere((s) => s.text == '12%').bold, isTrue);
      expect(spans.firstWhere((s) => s.text == 'flat').italic, isTrue);
      expect(spans.firstWhere((s) => s.text == 'appendix').underline, isTrue);
      expect(spans.first.bold, isFalse);
    });

    test('the inline limits keep only the start', () {
      final preview =
          parse(
                fixture('report.docx'),
                'report.docx',
                limits: const DocumentLimits(
                  blocks: 3,
                  chars: 2000,
                  rows: 6,
                  columns: 6,
                  sheets: 1,
                  cellChars: 120,
                  inflateBytes: 1024 * 1024,
                ),
              )
              as RichPreview;
      expect(preview.truncated, isTrue);
      expect(preview.blocks, hasLength(3));
    });

    test('deleted text, field codes and any namespace prefix', () {
      const ns =
          'xmlns:x="http://schemas.openxmlformats.org/wordprocessingml/2006/main"';
      final preview =
          parse(
                buildZip({
                  'word/document.xml':
                      '<x:document $ns><x:body>'
                      '<x:p><x:pPr><x:outlineLvl x:val="1"/></x:pPr>'
                      '<x:r><x:t>Kept</x:t></x:r>'
                      '<x:del><x:r><x:delText>removed</x:delText></x:r></x:del>'
                      '<x:r><x:instrText>PAGE</x:instrText></x:r>'
                      '<x:r><x:rPr><x:b x:val="0"/></x:rPr><x:t xml:space="preserve"> heading</x:t></x:r>'
                      '</x:p>'
                      '<x:p><x:r><x:t>a</x:t><x:tab/><x:t>b</x:t><x:br/><x:t>c</x:t></x:r></x:p>'
                      '<x:p/>'
                      '</x:body></x:document>',
                }),
                'a.docx',
              )
              as RichPreview;
      expect(preview.blocks.map(plain), ['h2 Kept heading', 'p a\tb\nc']);
      expect((preview.blocks.first as HeadingBlock).spans.single.bold, isFalse);
    });

    test('a document cut off at the inflate limit shows what was read', () {
      final body = StringBuffer('<w:document><w:body>');
      for (var i = 0; i < 2000; i++) {
        body.write('<w:p><w:r><w:t>Paragraph number $i</w:t></w:r></w:p>');
      }
      body.write('</w:body></w:document>');
      final preview =
          parse(
                buildZip({'word/document.xml': body.toString()}),
                'a.docx',
                limits: const DocumentLimits(
                  blocks: 4000,
                  chars: 1500000,
                  rows: 100,
                  columns: 10,
                  sheets: 1,
                  cellChars: 100,
                  inflateBytes: 4096,
                ),
              )
              as RichPreview;
      expect(preview.truncated, isTrue);
      expect(preview.blocks.length, inInclusiveRange(50, 200));
      expect(plain(preview.blocks.first), 'p Paragraph number 0');
    });
  });

  group('Excel', () {
    test('a real .xlsx: strings, numbers, dates, booleans, sheets', () {
      final preview =
          parse(fixture('budget.xlsx'), 'budget.xlsx') as SheetPreview;
      expect(preview.sheets.map((s) => s.name), ['Budget', 'Notes']);
      final budget = preview.sheets.first;
      expect(budget.rows, [
        ['Item', 'Qty', 'Price', 'Due', 'Paid'],
        ['Laptop', '2', '1499.5', '5 Nov 2026', 'TRUE'],
        ['Desk', '1', '0.3', '24 Dec 2026 14:30', 'FALSE'],
        ['Chair & mat', '4', '89'],
        ['Late row', '', '', '', '', '', '', 'Far column'],
      ]);
      expect(budget.rowNumbers, [1, 2, 3, 4, 7]);
      expect(preview.sheets.last.rows, [
        ['Remember the café order'],
        ['Second note'],
      ]);
      expect(preview.truncated, isFalse);
    });

    test('the inline limits read one sheet and a few cells', () {
      final preview =
          parse(
                fixture('budget.xlsx'),
                'budget.xlsx',
                limits: DocumentLimits.inline,
              )
              as SheetPreview;
      expect(preview.truncated, isTrue);
      expect(preview.sheets.single.name, 'Budget');
      // Column H of row 7 is past the six-column limit.
      expect(preview.sheets.single.rows.last, ['Late row']);
      expect(preview.sheets.single.columnCount, 5);
    });

    test('inline strings, formula results, errors and 1904 dates', () {
      final preview =
          parse(
                buildZip({
                  'xl/workbook.xml':
                      '<workbook xmlns:r="r"><workbookPr date1904="1"/><sheets>'
                      '<sheet name="Data" sheetId="1" r:id="rId7"/>'
                      '</sheets></workbook>',
                  'xl/_rels/workbook.xml.rels':
                      '<Relationships><Relationship Id="rId7" '
                      'Target="/xl/worksheets/odd-name.xml"/></Relationships>',
                  'xl/styles.xml':
                      '<styleSheet><numFmts>'
                      '<numFmt numFmtId="164" formatCode="[\$-409]h:mm\\ AM/PM"/>'
                      '<numFmt numFmtId="165" formatCode="0.00&quot; days&quot;"/>'
                      '</numFmts><cellXfs>'
                      '<xf numFmtId="0"/><xf numFmtId="14"/>'
                      '<xf numFmtId="164"/><xf numFmtId="165"/>'
                      '</cellXfs></styleSheet>',
                  'xl/worksheets/odd-name.xml':
                      '<worksheet><dimension ref="A1:D2"/><sheetData>'
                      '<row r="1">'
                      '<c r="A1" t="inlineStr"><is><r><t>rich </t></r><r><t>text</t></r><rPh><t>ignored</t></rPh></is></c>'
                      '<c r="B1"><f>SUM(1,2)</f><v>3</v></c>'
                      '<c r="C1" t="e"><v>#DIV/0!</v></c>'
                      '<c r="D1" t="str"><f>A1&amp;"x"</f><v>formula text</v></c>'
                      '</row>'
                      '<row r="2">'
                      '<c r="A2" s="1"><v>0</v></c>'
                      '<c r="B2" s="2"><v>0.75</v></c>'
                      '<c r="C2" s="3"><v>2.5</v></c>'
                      '<c r="D2" s="1"/>'
                      '</row>'
                      '</sheetData></worksheet>',
                }),
                'a.xlsx',
              )
              as SheetPreview;
      expect(preview.sheets.single.rows, [
        ['rich text', '3', '#DIV/0!', 'formula text'],
        ['1 Jan 1904', '18:00', '2.5'],
      ]);
    });

    test('numbers lose binary-fraction noise; serial dates convert', () {
      expect(formatCellNumber('0.30000000000000004'), '0.3');
      expect(formatCellNumber('1499.5'), '1499.5');
      expect(formatCellNumber('42'), '42');
      expect(formatCellNumber('42.0'), '42');
      expect(formatCellNumber('1E+20'), '1E+20');
      expect(formatCellNumber('0.0000000000015'), '1.5E-12');
      expect(formatCellNumber('-0.125'), '-0.125');
      expect(formatCellNumber('n/a'), 'n/a');
      expect(formatSerialDate(1), '1 Jan 1900');
      expect(formatSerialDate(59), '28 Feb 1900');
      expect(formatSerialDate(61), '1 Mar 1900');
      expect(formatSerialDate(46331), '5 Nov 2026');
      expect(formatSerialDate(0.5, kind: 1), '12:00');
      expect(formatSerialDate(46331.5, kind: 2), '5 Nov 2026 12:00');
    });

    test('a huge sheet stops at the row limit and reports its size', () {
      final data = StringBuffer(
        '<worksheet><dimension ref="A1:B90000"/><sheetData>',
      );
      for (var i = 1; i <= 9000; i++) {
        data.write('<row r="$i"><c r="A$i"><v>$i</v></c></row>');
      }
      data.write('</sheetData></worksheet>');
      final preview =
          parse(
                buildZip({
                  'xl/workbook.xml':
                      '<workbook><sheets><sheet name="Big" r:id="rId1"/></sheets></workbook>',
                  'xl/worksheets/sheet1.xml': data.toString(),
                }),
                'a.xlsx',
              )
              as SheetPreview;
      final sheet = preview.sheets.single;
      expect(preview.truncated, isTrue);
      expect(sheet.rows, hasLength(DocumentLimits.full.rows));
      expect(sheet.totalRows, 90000);
      expect(sheet.rows.last.single, '${DocumentLimits.full.rows}');
    });
  });

  group('PowerPoint', () {
    test('a real .pptx: slides in order with titles, bullets and tables', () {
      final preview =
          parse(fixture('roadmap.pptx'), 'roadmap.pptx') as RichPreview;
      expect(preview.blocks.map(plain), [
        'slide 1',
        'h2 Parallax roadmap',
        'p November 2026',
        'slide 2',
        'h2 Next steps',
        'li0 • Ship file previews',
        'li1 • Word and Excel first',
        'li0 • Fix the reconnect bug',
        'slide 3',
        'h2 Numbers',
        'table Metric|Value/Users|42',
        'p Source: internal',
      ]);
    });

    test('slides follow the presentation order, not their file names', () {
      String slide(String title) =>
          '<p:sld><p:cSld><p:spTree><p:sp><p:nvSpPr><p:nvPr><p:ph type="title"/></p:nvPr></p:nvSpPr>'
          '<p:txBody><a:p><a:r><a:t>$title</a:t></a:r></a:p></p:txBody></p:sp></p:spTree></p:cSld></p:sld>';
      final preview =
          parse(
                buildZip({
                  'ppt/presentation.xml':
                      '<p:presentation><p:sldIdLst>'
                      '<p:sldId id="256" r:id="rId3"/><p:sldId id="257" r:id="rId2"/>'
                      '</p:sldIdLst></p:presentation>',
                  'ppt/_rels/presentation.xml.rels':
                      '<Relationships>'
                      '<Relationship Id="rId2" Target="slides/slide1.xml"/>'
                      '<Relationship Id="rId3" Target="slides/slide2.xml"/>'
                      '</Relationships>',
                  'ppt/slides/slide1.xml': slide('Second'),
                  'ppt/slides/slide2.xml': slide('First'),
                }),
                'a.pptx',
              )
              as RichPreview;
      expect(preview.blocks.map(plain), [
        'slide 1',
        'h2 First',
        'slide 2',
        'h2 Second',
      ]);
    });
  });

  group('background parsing', () {
    test('runs on another isolate and returns the preview', () async {
      final preview = await parseDocumentInBackground(
        DocumentRequest(
          bytes: fixture('budget.xlsx'),
          format: DocumentFormat.spreadsheet,
          name: 'budget.xlsx',
        ),
      );
      expect((preview as SheetPreview).sheets.first.rows.first.first, 'Item');
    });

    test('a file that cannot be parsed gives null, not an error', () async {
      expect(
        await parseDocumentInBackground(
          DocumentRequest(
            bytes: Uint8List.fromList([1, 2, 3]),
            format: DocumentFormat.word,
            name: 'a.docx',
          ),
        ),
        isNull,
      );
    });

    test('empty previews are recognised', () {
      expect(isEmptyPreview(const TextPreview('  \n')), isTrue);
      expect(isEmptyPreview(const TextPreview('x')), isFalse);
      expect(isEmptyPreview(const RichPreview([SlideBlock(1)])), isTrue);
      expect(
        isEmptyPreview(const SheetPreview([DocSheet(name: 'a', rows: [])])),
        isTrue,
      );
    });
  });

  test('column letters', () {
    expect(columnLetters(0), 'A');
    expect(columnLetters(25), 'Z');
    expect(columnLetters(26), 'AA');
    expect(columnLetters(701), 'ZZ');
    expect(columnLetters(702), 'AAA');
  });
}
