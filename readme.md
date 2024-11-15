Here's a quick tutorial on using `winget`.

- Winget comes pre-installed on new computers, but if you don't have it, just install the [App Installer](https://www.microsoft.com/en-us/p/app-installer/9nblggh4nns1) from the Microsoft Store.
- `winget list` shows all applications you currently have installed and labels which ones are available through winget. This is a good way to prepare your own setup script, especially if you're planning to get a new computer.
- `winget search <name of app>` to find out if an app you want can be installed through winget.
- `winget install` and `winget uninstall` do exactly what you think.

You can install each app separately using those commands. Or if you want to use the script to automate it, here's how to do that:

1. Edit the `InstallSoftware.ps1` file to include the apps you want.
2. Start PowerShell as administrator.
3. If running scripts is blocked (it should be), you can temporarily unblock them with `Set-ExecutionPolicy -ExecutionPolicy Unrestricted -Scope Process`.
4. Run the script and enjoy!
