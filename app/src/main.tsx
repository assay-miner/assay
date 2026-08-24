import { StrictMode } from "react";
import { createRoot } from "react-dom/client";
import { BrowserRouter, Routes, Route } from "react-router-dom";
import { I18nProvider } from "./i18n";
import Sheet from "./components/Sheet";
import Home from "./pages/Home";
import Mechanism from "./pages/Mechanism";
import Tasks from "./pages/Tasks";
import Docs from "./pages/Docs";
import Contact from "./pages/Contact";
import NotFound from "./pages/NotFound";
import "./styles.css";

createRoot(document.getElementById("root")!).render(
  <StrictMode>
    <I18nProvider>
      <BrowserRouter>
        <Routes>
          {/* The home page is its own plate and carries no sheet chrome. */}
          <Route path="/" element={<Home />} />
          <Route element={<Sheet />}>
            <Route path="mechanism" element={<Mechanism />} />
            <Route path="tasks" element={<Tasks />} />
            <Route path="docs" element={<Docs />} />
            <Route path="contact" element={<Contact />} />
            <Route path="*" element={<NotFound />} />
          </Route>
        </Routes>
      </BrowserRouter>
    </I18nProvider>
  </StrictMode>,
);
