"""Builds the Office fixtures for test/file_preview_office_test.dart.

Run with python-docx, openpyxl and python-pptx installed:
    python make_fixtures.py <output directory>
"""
import datetime
import sys
from pathlib import Path

import docx
import openpyxl
from pptx import Presentation
from pptx.util import Inches

out = Path(sys.argv[1])

# --- Word -------------------------------------------------------------------
d = docx.Document()
d.add_heading('Quarterly report', level=0)  # Title style
d.add_heading('Summary', level=1)
p = d.add_paragraph('Revenue grew ')
p.add_run('12%').bold = True
p.add_run(' against a ')
p.add_run('flat').italic = True
p.add_run(' market, see ')
p.add_run('appendix').underline = True
p.add_run('.')
d.add_paragraph('Hire two engineers', style='List Bullet')
d.add_paragraph('Open the Perth office', style='List Bullet')
d.add_paragraph('Draft the plan', style='List Number')
d.add_paragraph('Review with finance', style='List Number')
d.add_heading('Figures', level=2)
t = d.add_table(rows=3, cols=3)
for r, row in enumerate([['Region', 'Q1', 'Q2'], ['East', '10', '12'], ['West', '7', '9']]):
    for c, text in enumerate(row):
        t.cell(r, c).text = text
d.add_paragraph('Tom & Jerry <done> "quoted" café')
d.save(out / 'report.docx')

# --- Excel ------------------------------------------------------------------
wb = openpyxl.Workbook()
ws = wb.active
ws.title = 'Budget'
ws.append(['Item', 'Qty', 'Price', 'Due', 'Paid'])
ws.append(['Laptop', 2, 1499.5, datetime.date(2026, 11, 5), True])
ws.append(['Desk', 1, 0.1 + 0.2, datetime.datetime(2026, 12, 24, 14, 30), False])
ws.append(['Chair & mat', 4, 89, None, None])
ws['A7'] = 'Late row'
ws['H7'] = 'Far column'
notes = wb.create_sheet('Notes')
notes.append(['Remember the café order'])
notes.append(['Second note'])
hidden = wb.create_sheet('Secret')
hidden.append(['do not show'])
hidden.sheet_state = 'hidden'
wb.save(out / 'budget.xlsx')

# --- PowerPoint -------------------------------------------------------------
prs = Presentation()
s = prs.slides.add_slide(prs.slide_layouts[0])
s.shapes.title.text = 'Parallax roadmap'
s.placeholders[1].text = 'November 2026'
s = prs.slides.add_slide(prs.slide_layouts[1])
s.shapes.title.text = 'Next steps'
body = s.placeholders[1].text_frame
body.text = 'Ship file previews'
para = body.add_paragraph()
para.text = 'Word and Excel first'
para.level = 1
para = body.add_paragraph()
para.text = 'Fix the reconnect bug'
s = prs.slides.add_slide(prs.slide_layouts[5])
s.shapes.title.text = 'Numbers'
table = s.shapes.add_table(2, 2, Inches(1), Inches(2), Inches(6), Inches(1.5)).table
table.cell(0, 0).text = 'Metric'
table.cell(0, 1).text = 'Value'
table.cell(1, 0).text = 'Users'
table.cell(1, 1).text = '42'
box = s.shapes.add_textbox(Inches(1), Inches(4.5), Inches(6), Inches(1))
box.text_frame.text = 'Source: internal'
prs.save(out / 'roadmap.pptx')
print('fixtures written to', out)
