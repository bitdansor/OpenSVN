#pragma once

#include "App.xaml.g.h"

namespace winrt::OpenSVN::implementation {

// Application entry point. Deliberately thin: everything that can be tested
// (services, parsers, models) lives outside the XAML layer, so that CI can run it
// without a desktop session.
struct App : AppT<App> {
    App();

    void OnLaunched(winrt::Microsoft::UI::Xaml::LaunchActivatedEventArgs const& args);

private:
    winrt::Microsoft::UI::Xaml::Window window_{nullptr};
};

}  // namespace winrt::OpenSVN::implementation
