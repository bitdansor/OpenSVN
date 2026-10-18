#include "pch.h"

#include "App.xaml.h"
#include "MainWindow.xaml.h"

using namespace winrt;
using namespace Microsoft::UI::Xaml;

namespace winrt::OpenSVN::implementation {

App::App() {
    // WinUI 3 needs the XAML controls initialised before any window is created.
    InitializeComponent();
}

void App::OnLaunched(LaunchActivatedEventArgs const&) {
    window_ = make<MainWindow>();
    window_.Activate();
}

}  // namespace winrt::OpenSVN::implementation
