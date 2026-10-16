@echo off
REM Build MacTempWin as a single self-contained win-x64 exe.
dotnet publish MacTempWin.csproj -c Release -r win-x64 --self-contained true ^
  -p:PublishSingleFile=true -p:EnableCompressionInSingleFile=true ^
  -p:IncludeNativeLibrariesForSelfExtract=true -o ..\dist\win
echo Done: ..\dist\win\MacTempWin.exe
