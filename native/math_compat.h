#ifndef QUINTA_MATH_COMPAT_H
#define QUINTA_MATH_COMPAT_H

extern double pow(double, double);
extern double __exp10(double);
extern float __exp10f(float);
extern float sinf(float), cosf(float);
extern double sin(double), cos(double);
struct QuintaFloat2 { float sine, cosine; };
struct QuintaDouble2 { double sine, cosine; };
extern struct QuintaFloat2 __sincosf_stret(float);
extern struct QuintaDouble2 __sincos_stret(double);
extern struct QuintaFloat2 __sincospif_stret(float);
extern struct QuintaDouble2 __sincospi_stret(double);

/* Older Darling builds let Clang turn pow(10, x) inside __exp10 into a
 * tail-call to __exp10 itself. Roblox's audio setup then spins forever.
 * A volatile function pointer keeps this call indirect even with newer
 * Darwin-target Clang and LTO, preventing the same rewrite in our shim.
 * Keep the existing float wrapper's double calculation and final rounding. */
static double (*volatile quinta_exp10_power)(double, double) = pow;

static double quinta_exp10(double value) {
    return quinta_exp10_power(10.0, value);
}

static float quinta_exp10f(float value) {
    return (float)quinta_exp10_power(10.0, (double)value);
}

/* The older 4312 runtime also compiles sinf/cosf pairs into calls to the
 * sincos wrapper being defined. Both volatile calls are necessary: Clang
 * otherwise combines the pair back into the same recursive symbol. */
static float (*volatile quinta_sine_float)(float) = sinf;
static float (*volatile quinta_cosine_float)(float) = cosf;
static double (*volatile quinta_sine)(double) = sin;
static double (*volatile quinta_cosine)(double) = cos;
static struct QuintaFloat2 quinta_sincosf(float value) {
    struct QuintaFloat2 result = {quinta_sine_float(value), quinta_cosine_float(value)};
    return result;
}
static struct QuintaDouble2 quinta_sincos(double value) {
    struct QuintaDouble2 result = {quinta_sine(value), quinta_cosine(value)};
    return result;
}
static struct QuintaFloat2 quinta_sincospif(float value) {
    return quinta_sincosf((float)((double)value * 3.14159265358979323846264338327950288));
}
static struct QuintaDouble2 quinta_sincospi(double value) {
    return quinta_sincos(value * 3.14159265358979323846264338327950288);
}

#endif
