#pragma once

#include "MainWindow.g.h"

namespace winrt::OpenSVN::implementation {

// Shell only: navigation between the five pages that stage 4 fills in. No SVN
// call is made from this class — it talks to the view models, and the view models
// talk to SVNService. Keeping that rule here is what stops business logic from
// leaking into XAML code-behind later.
struct MainWindow : MainWindowT<MainWindow> {
    MainWindow();

    void OnNavigationSelectionChanged(
        winrt::Microsoft::UI::Xaml::Controls::NavigationView const& sender,
        winrt::Microsoft::UI::Xaml::Controls::NavigationViewSelectionChangedEventArgs const& args);

private:
    void ShowSection(std::wstring_view tag);
};

}  // namespace winrt::OpenSVN::implementation

namespace winrt::OpenSVN::factory_implementation {
struct MainWindow : MainWindowT<MainWindow, implementation::MainWindow> {};
}  // namespace winrt::OpenSVN::factory_implementation
