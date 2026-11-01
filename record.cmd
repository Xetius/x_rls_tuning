@echo off
rem Start the Tuning Telemetry recorder. Leave this window open while you drive.
py "%~dp0recorder\recorder.py" %*
pause
