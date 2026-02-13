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
}
