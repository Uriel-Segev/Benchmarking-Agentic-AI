import json
import sys
import os
import glob
import matplotlib.pyplot as plt
import statistics
import numpy as np
from scipy.optimize import curve_fit

def main():
    # check if the usage was correct, has to provide a results directory as command line argument
    if len(sys.argv) < 2:
        print("Usage: display_json_time.py <results_dir>")
        print("  results_dir: path containing summary.json and probes/ subdirectory")
        sys.exit(1)

    results_dir = sys.argv[1]

    try:
        # load summary.json for top-level metadata
        summary_path = os.path.join(results_dir, "summary.json")
        with open(summary_path, 'r') as f:
            summary = json.load(f)

        repeats_per_count = summary.get("repeats_per_probe", 1)
        hypervisor = summary.get("hypervisor", "")
        task = summary.get("task", "")
        label = summary.get("label", "")

        # load all per-probe files, sort by filename (probe_NNN_nMMMM_rR.json)
        probes_dir = os.path.join(results_dir, "probes")
        probe_files = sorted(glob.glob(os.path.join(probes_dir, "probe_*.json")))

        if not probe_files:
            print(f"No probe files found in {probes_dir}/")
            sys.exit(1)

        # group probes by vm_count, skipping baseline (N=1 sanity check) probes
        probes_by_count = {}
        for probe_path in probe_files:
            with open(probe_path, 'r') as f:
                probe = json.load(f)
            if probe.get("is_baseline", False):
                continue
            vm_count = probe["vm_count"]
            probes_by_count.setdefault(vm_count, []).append(probe)

        if not probes_by_count:
            print("No non-baseline probes found.")
            sys.exit(1)

        avg_boot_time = []
        avg_solution_time = []
        avg_shutdown_time = []
        instance_count = []
        completion_rate = []

        boot_stddev = []
        solution_stddev = []
        shutdown_stddev = []
        completion_stddev = []

        for vm_count in sorted(probes_by_count.keys()):
            probes = probes_by_count[vm_count]

            temp_avg_boot_time = []
            temp_avg_solution_time = []
            temp_avg_shutdown_time = []
            temp_completion_rate = []

            for probe in probes:
                ts = probe.get("timing_summary")
                if ts:
                    temp_avg_boot_time.append(ts["boot_time_s"]["avg"])
                    temp_avg_solution_time.append(ts["solution_time_s"]["avg"])
                    temp_avg_shutdown_time.append(ts["shutdown_time_s"]["avg"])
                completed = probe.get("completed", 0)
                total = probe.get("total", vm_count)
                temp_completion_rate.append((completed / total) * 100 if total > 0 else 0)

            # skip vm_counts where every repeat crashed before recording timing
            if not temp_avg_boot_time:
                continue

            avg_boot_time.append(sum(temp_avg_boot_time) / len(temp_avg_boot_time))
            avg_solution_time.append(sum(temp_avg_solution_time) / len(temp_avg_solution_time))
            avg_shutdown_time.append(sum(temp_avg_shutdown_time) / len(temp_avg_shutdown_time))
            instance_count.append(str(vm_count))
            completion_rate.append(sum(temp_completion_rate) / len(temp_completion_rate))

            boot_stddev.append(statistics.stdev(temp_avg_boot_time) if len(temp_avg_boot_time) > 1 else 0)
            solution_stddev.append(statistics.stdev(temp_avg_solution_time) if len(temp_avg_solution_time) > 1 else 0)
            shutdown_stddev.append(statistics.stdev(temp_avg_shutdown_time) if len(temp_avg_shutdown_time) > 1 else 0)
            completion_stddev.append(statistics.stdev(temp_completion_rate) if len(temp_completion_rate) > 1 else 0)

        if not instance_count:
            print("No probes with timing data found.")
            sys.exit(1)

        # print summary table to terminal
        title_str = f"{task}  [{hypervisor}]  label={label}" if task else results_dir
        print(f"\n{title_str}")
        print(f"\n{'VMs':>6} {'Boot(s)':>10} {'Solution(s)':>12} {'Shutdown(s)':>12} {'Complete%':>10}")
        print("-" * 54)
        for k in range(len(instance_count)):
            print(f"{instance_count[k]:>6} {avg_boot_time[k]:>10.3f} {avg_solution_time[k]:>12.3f} {avg_shutdown_time[k]:>12.3f} {completion_rate[k]:>9.1f}%")
        print()

        # curve fitting analysis
        x = np.array([int(v) for v in instance_count], dtype=float)

        def linear(x, a, b):
            return a * x + b
        def quadratic(x, a, b, c):
            return a * x**2 + b * x + c
        def exponential(x, a, b):
            return a * np.exp(b * x)
        def logarithmic(x, a, b):
            return a * np.log(x) + b

        models = [
            ("Linear    (ax+b)",        linear,      [1, 0]),
            ("Quadratic (ax²+bx+c)",    quadratic,   [0.01, 1, 0]),
            ("Exponential (ae^bx)",     exponential, [1, 0.01]),
            ("Logarithmic (a·ln(x)+b)", logarithmic, [1, 0]),
        ]

        def r_squared(y_actual, y_predicted):
            ss_res = np.sum((y_actual - y_predicted) ** 2)
            ss_tot = np.sum((y_actual - np.mean(y_actual)) ** 2)
            if ss_tot == 0:
                return 0.0
            return 1 - (ss_res / ss_tot)

        datasets = [
            ("Boot Time",     np.array(avg_boot_time)),
            ("Solution Time", np.array(avg_solution_time)),
            ("Shutdown Time", np.array(avg_shutdown_time)),
        ]

        print("=" * 60)
        print("CURVE FITTING ANALYSIS (R² values)")
        print("=" * 60)
        for ds_name, y in datasets:
            print(f"\n  {ds_name}:")
            best_r2 = -999
            best_name = ""
            for model_name, model_fn, p0 in models:
                try:
                    popt, _ = curve_fit(model_fn, x, y, p0=p0, maxfev=10000)
                    y_pred = model_fn(x, *popt)
                    r2 = r_squared(y, y_pred)
                    if r2 > best_r2:
                        best_r2 = r2
                        best_name = model_name
                    print(f"    {model_name:<28} R² = {r2:.6f}")
                except Exception:
                    print(f"    {model_name:<28} R² = FAILED")
            print(f"    >> Best fit: {best_name} (R² = {best_r2:.6f})")
        print()

        # numeric x values for properly spaced plots
        x_num = np.array([int(v) for v in instance_count])
        gaps = np.diff(x_num)
        bar_width = min(gaps) * 0.8 if len(gaps) > 0 else 0.8

        plot_title_suffix = f"({repeats_per_count} repeats)"

        # average boot time plot
        fig, ax1 = plt.subplots()
        ax1.bar(x_num, avg_boot_time, width=bar_width, yerr=boot_stddev, capsize=5)
        ax1.set_xlabel('# of instances')
        ax1.set_ylabel('avg boot time')
        ax1.set_xticks(x_num)

        ax2 = ax1.twinx()
        ax2.plot(x_num, completion_rate, color='red', marker='o')
        ax2.errorbar(x_num, completion_rate, yerr=completion_stddev, color='red', fmt='none', capsize=3)
        ax2.set_ylabel('completion rate %')

        plt.title(f'Boot Time vs. # Instances {plot_title_suffix}')
        plt.show()

        # average solution time plot
        fig, ax1 = plt.subplots()
        ax1.bar(x_num, avg_solution_time, width=bar_width, yerr=solution_stddev, capsize=5)
        ax1.set_xlabel('# of instances')
        ax1.set_ylabel('avg solution time')
        ax1.set_xticks(x_num)

        ax2 = ax1.twinx()
        ax2.plot(x_num, completion_rate, color='red', marker='o')
        ax2.errorbar(x_num, completion_rate, yerr=completion_stddev, color='red', fmt='none', capsize=3)
        ax2.set_ylabel('completion rate %')

        plt.title(f'Solution Time vs. # Instances {plot_title_suffix}')
        plt.show()

        # average shutdown time plot
        fig, ax1 = plt.subplots()
        ax1.bar(x_num, avg_shutdown_time, width=bar_width, yerr=shutdown_stddev, capsize=5)
        ax1.set_xlabel('# of instances')
        ax1.set_ylabel('avg shutdown time')
        ax1.set_xticks(x_num)

        ax2 = ax1.twinx()
        ax2.plot(x_num, completion_rate, color='red', marker='o')
        ax2.errorbar(x_num, completion_rate, yerr=completion_stddev, color='red', fmt='none', capsize=3)
        ax2.set_ylabel('completion rate %')

        plt.title(f'Shutdown Time vs. # Instances {plot_title_suffix}')
        plt.show()

    except FileNotFoundError as e:
        print(f"File not found: {e}")
    except json.JSONDecodeError:
        print("Error: could not decode JSON")
    except Exception as e:
        print(f"An error has occurred: {e}")


if __name__ == "__main__":
    main()
