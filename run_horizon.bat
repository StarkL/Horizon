@echo off
set PATH=C:\Python312;%PATH%
set PYTHONIOENCODING=utf-8
set PYTHONUTF8=1
cd /d "D:\projects\信息聚合\Horizon"
"C:\Python312\Scripts\horizon.exe" --hours 24 >> "D:\projects\信息聚合\Horizon\run.log" 2>&1
