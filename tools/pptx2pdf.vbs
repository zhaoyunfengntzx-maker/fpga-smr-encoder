Option Explicit
' PowerPoint 晚绑定导出：pptx -> pdf，并可选导出第 1 页 PNG。
' 用法: cscript //nologo tools\pptx2pdf.vbs <src.pptx> <dst.pdf> [png-dir] [png-width]
Dim src, dstPdf, pngDir, pngW, app, pres, fso, f
If WScript.Arguments.Count < 2 Then
    WScript.Echo "usage: pptx2pdf.vbs src.pptx dst.pdf [pngdir] [pngwidth]"
    WScript.Quit 2
End If
src = WScript.Arguments(0)
dstPdf = WScript.Arguments(1)
pngDir = ""
pngW = 0
If WScript.Arguments.Count >= 3 Then pngDir = WScript.Arguments(2)
If WScript.Arguments.Count >= 4 Then pngW = CLng(WScript.Arguments(3))

Set app = CreateObject("PowerPoint.Application")
Set pres = app.Presentations.Open(src, True, False, False)
pres.SaveAs dstPdf, 32
If pngW > 0 And Len(pngDir) > 0 Then pres.Export pngDir, "PNG", pngW, 0
pres.Close
app.Quit

Set fso = CreateObject("Scripting.FileSystemObject")
Set f = fso.GetFile(dstPdf)
WScript.Echo "saved " & dstPdf & " bytes=" & f.Size
