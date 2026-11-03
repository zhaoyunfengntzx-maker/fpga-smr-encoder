Option Explicit
' Word 晚绑定导出 PDF（本机 Word 类型库损坏，必须用 VBS/IDispatch，不能用 pywin32 makepy）。
' 用法: cscript //nologo tools\docx2pdf.vbs <src.docx> <dst.pdf>
Dim src, dst, app, doc, pages
If WScript.Arguments.Count < 2 Then
    WScript.Echo "usage: docx2pdf.vbs src.docx dst.pdf"
    WScript.Quit 2
End If
src = WScript.Arguments(0)
dst = WScript.Arguments(1)

Set app = CreateObject("Word.Application")
app.Visible = False
app.DisplayAlerts = 0
Set doc = app.Documents.Open(src, False, True, False)
doc.Repaginate
pages = doc.ComputeStatistics(2)
' ExportAsFixedFormat(OutputFileName, ExportFormat=17(wdExportFormatPDF), OpenAfterExport,
'   OptimizeFor, Range, From, To, Item, IncludeDocProps, KeepIRM, CreateBookmarks,
'   DocStructureTags, BitmapMissingFonts, UseISO19005_1)
doc.ExportAsFixedFormat dst, 17, False, 0, 0, 0, 0, 0, True, True, 0, True, True, False
doc.Close False
app.Quit

Dim fso, f
Set fso = CreateObject("Scripting.FileSystemObject")
Set f = fso.GetFile(dst)
WScript.Echo "saved " & dst & " pages=" & pages & " bytes=" & f.Size
