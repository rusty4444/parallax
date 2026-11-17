"""Writes test/pdf_fixtures.dart: a three-page PDF with known shapes, and the
same file locked with a password. They are small enough to live in the test
source, which lets the on-device tests (integration_test/pdf_*_test.dart)
use them without pushing files to the device.

Run from the repository root with pypdf installed (for the locked copy):
    python tools/make_pdf_fixtures.py

The plain file is the same on every run. The locked one is not (its
encryption uses a fresh document ID); any run's output will do.
"""
import base64
import io
from pathlib import Path

from pypdf import PdfReader, PdfWriter


def build(pages):
    """A PDF from (width, height, content stream) per page, in points."""
    objects = []

    def add(body):
        objects.append(body)
        return len(objects)

    catalog = add(None)
    tree = add(None)
    font = add(b"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>")
    kids = []
    for width, height, content in pages:
        stream = add(
            b"<< /Length %d >>\nstream\n" % len(content) + content + b"\nendstream"
        )
        kids.append(
            add(
                b"<< /Type /Page /Parent %d 0 R /MediaBox [0 0 %d %d] "
                b"/Resources << /Font << /F1 %d 0 R >> >> /Contents %d 0 R >>"
                % (tree, width, height, font, stream)
            )
        )
    objects[catalog - 1] = b"<< /Type /Catalog /Pages %d 0 R >>" % tree
    objects[tree - 1] = b"<< /Type /Pages /Kids [%s] /Count %d >>" % (
        b" ".join(b"%d 0 R" % kid for kid in kids),
        len(kids),
    )
    out = io.BytesIO()
    out.write(b"%PDF-1.4\n%\xe2\xe3\xcf\xd3\n")
    offsets = []
    for number, body in enumerate(objects, 1):
        offsets.append(out.tell())
        out.write(b"%d 0 obj\n" % number + body + b"\nendobj\n")
    xref = out.tell()
    out.write(b"xref\n0 %d\n" % (len(objects) + 1))
    out.write(b"0000000000 65535 f \n")
    for offset in offsets:
        out.write(b"%010d 00000 n \n" % offset)
    out.write(
        b"trailer\n<< /Size %d /Root %d 0 R >>\nstartxref\n%d\n%%%%EOF\n"
        % (len(objects) + 1, catalog, xref)
    )
    return out.getvalue()


sample = build(
    [
        # A4 portrait: a title, and a black block 100-300 by 100-200 points
        # from the bottom left.
        (
            595,
            842,
            b"BT /F1 24 Tf 72 760 Td (Parallax PDF page 1) Tj ET\n"
            b"BT /F1 12 Tf 72 730 Td (Quarterly report, November 2026) Tj ET\n"
            b"0 0 0 rg 100 100 200 100 re f",
        ),
        # A4 landscape, all red.
        (
            842,
            595,
            b"1 0 0 rg 0 0 842 595 re f\n"
            b"BT /F1 24 Tf 1 1 1 rg 72 500 Td (Page 2) Tj ET",
        ),
        # A 200 point square, all blue.
        (200, 200, b"0 0 1 rg 0 0 200 200 re f"),
    ]
)

reader = PdfReader(io.BytesIO(sample))
assert len(reader.pages) == 3
writer = PdfWriter()
for page in reader.pages:
    writer.add_page(page)
writer.encrypt(user_password="secret", owner_password="owner", algorithm="RC4-128")
buffer = io.BytesIO()
writer.write(buffer)
locked = buffer.getvalue()


def literal(data):
    text = base64.b64encode(data).decode()
    return "\n".join(f"    '{text[at:at + 68]}'" for at in range(0, len(text), 68))


Path("test/pdf_fixtures.dart").write_text(
    f"""// PDF fixtures for test/pdf_preview_test.dart and the on-device tests in
// integration_test/. Written by tools/make_pdf_fixtures.py; don't edit.
import 'dart:convert';
import 'dart:typed_data';

/// Three pages: A4 portrait with a title and a black block 100–300 by
/// 100–200 points from the bottom left; A4 landscape, all red; a 200 point
/// square, all blue.
final Uint8List samplePdf = base64.decode(
{literal(sample)},
);

/// [samplePdf] locked with a password.
final Uint8List lockedPdf = base64.decode(
{literal(locked)},
);
"""
)
print(f"sample {len(sample)} bytes, locked {len(locked)} bytes")
