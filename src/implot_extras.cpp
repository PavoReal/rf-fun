#include "implot.h"

extern "C" {
    void rfFunGetPlotLimits(double* x_min, double* x_max, double* y_min, double* y_max) {
        ImPlotRect limits = ImPlot::GetPlotLimits();
        *x_min = limits.X.Min;
        *x_max = limits.X.Max;
        *y_min = limits.Y.Min;
        *y_max = limits.Y.Max;
    }

    void rfFunGetPlotPos(float* x, float* y) {
        ImVec2 pos = ImPlot::GetPlotPos();
        *x = pos.x; *y = pos.y;
    }

    void rfFunGetPlotSize(float* w, float* h) {
        ImVec2 size = ImPlot::GetPlotSize();
        *w = size.x; *h = size.y;
    }

    bool rfFunDragLineX(int id, double* value, float r, float g, float b, float a, float thickness) {
        ImVec4 col(r, g, b, a);
        return ImPlot::DragLineX(id, value, col, thickness);
    }

    void rfFunPlotBandX(double x_min, double x_max, float r, float g, float b, float a) {
        ImPlotRect limits = ImPlot::GetPlotLimits();
        ImVec2 rmin = ImPlot::PlotToPixels(x_min, limits.Y.Max);
        ImVec2 rmax = ImPlot::PlotToPixels(x_max, limits.Y.Min);
        ImPlot::PushPlotClipRect();
        ImPlot::GetPlotDrawList()->AddRectFilled(rmin, rmax, IM_COL32(
            (unsigned char)(r * 255), (unsigned char)(g * 255),
            (unsigned char)(b * 255), (unsigned char)(a * 255)));
        ImPlot::PopPlotClipRect();
    }
}
