import json
import sys
import matplotlib.pyplot as plt
import statistics

def main():
    # check if the usage was correct, has to provide a json file as command line argument
    if len(sys.argv) < 2:
        print("Not enough args, Usage: display_json_time.py file_name.json")
        sys.exit(1)
    
    # extract the json file name
    file_name = sys.argv[1]


    try:
        #open the file and load it as json
        with open(file_name, 'r') as file:
            #get json data
            data = json.load(file)

            repeats_per_count = data["repeats_per_count"] #amount of repeats of each # of instances run

            avg_boot_time = [] #declare avg boot time array
            avg_solution_time = [] #declare avg solution time array
            avg_shutdown_time = [] #declare avg shutdown time array
            instance_count = [] #declare instance count for each run (collection of data)
            completion_rate = [] #declare array for amount of VMs that completed the task

            #declare temporary arrays so that i can average the repeats before adding to official arrays
            temp_avg_boot_time = []
            temp_avg_solution_time = []
            temp_avg_shutdown_time = []
            temp_completion_rate = []

            #declare standard deviation arrays
            boot_stddev = []
            solution_stddev = []
            shutdown_stddev = []
            completion_stddev = []

            #loop through each run
            for i in range(0, len(data["runs"]), repeats_per_count):
                #clear temps
                temp_avg_boot_time = []
                temp_avg_solution_time = []
                temp_avg_shutdown_time = []
                temp_completion_rate = []

                for j in range(repeats_per_count):
                    #if data wasn't collected (likely crashed) then ignore it
                    if "timing_summary" in data["runs"][i+j]:
                        temp_avg_boot_time.append(data["runs"][i+j]["timing_summary"]["boot_time_s"]["avg"])
                        temp_avg_solution_time.append(data["runs"][i+j]["timing_summary"]["solution_time_s"]["avg"])
                        temp_avg_shutdown_time.append(data["runs"][i+j]["timing_summary"]["shutdown_time_s"]["avg"])
                        temp_completion_rate.append((data["runs"][i+j]["completed"] / (data["runs"][i+j]["total_instances"])) * 100)
                #fill in values (averages)
                avg_boot_time.append(sum(temp_avg_boot_time) / len(temp_avg_boot_time))
                avg_solution_time.append(sum(temp_avg_solution_time) / len(temp_avg_solution_time))
                avg_shutdown_time.append(sum(temp_avg_shutdown_time) / len(temp_avg_shutdown_time))
                instance_count.append(str(data["runs"][i]["vm_count"]))
                completion_rate.append(sum(temp_completion_rate) / len(temp_completion_rate))      

                #collect standard deviation values and store them
                boot_stddev.append(statistics.stdev(temp_avg_boot_time) if len(temp_avg_boot_time) > 1 else 0)
                solution_stddev.append(statistics.stdev(temp_avg_solution_time) if len(temp_avg_solution_time) > 1 else 0)
                shutdown_stddev.append(statistics.stdev(temp_avg_shutdown_time) if len(temp_avg_shutdown_time) > 1 else 0)
                completion_stddev.append(statistics.stdev(temp_completion_rate) if len(temp_completion_rate) > 1 else 0)      

            #average boot time plot:
            fig, ax1 = plt.subplots()
            ax1.bar(instance_count, avg_boot_time, yerr=boot_stddev, capsize=5)
            ax1.set_xlabel('# of instances')
            ax1.set_ylabel('avg boot time')
            
            ax2 = ax1.twinx()
            ax2.plot(instance_count, completion_rate, color='red', marker='o')
            ax2.errorbar(instance_count, completion_rate, yerr=completion_stddev, color='red', fmt='none', capsize=3)
            ax2.set_ylabel('completion rate %')
            
            plt.title(f'Boot Time vs. # Instances ({repeats_per_count} repeats)')
            plt.show()

            #average solution time plot:
            fig, ax1 = plt.subplots()
            ax1.bar(instance_count, avg_solution_time, yerr=solution_stddev, capsize=5)
            ax1.set_xlabel('# of instances')
            ax1.set_ylabel('avg solution time')

            ax2 = ax1.twinx()
            ax2.plot(instance_count, completion_rate, color='red', marker='o')
            ax2.errorbar(instance_count, completion_rate, yerr=completion_stddev, color='red', fmt='none', capsize=3)
            ax2.set_ylabel('completion rate %')

            plt.title(f'Solution Time vs. # Instances ({repeats_per_count} repeats)')
            plt.show()


            #average shutdown time plot:
            fig, ax1 = plt.subplots()           
            ax1.bar(instance_count, avg_shutdown_time, yerr=shutdown_stddev, capsize=5)
            ax1.set_xlabel('# of instances')
            ax1.set_ylabel('avg shutdown time')

            ax2 = ax1.twinx()
            ax2.plot(instance_count, completion_rate, color='red', marker='o')
            ax2.errorbar(instance_count, completion_rate, yerr=completion_stddev, color='red', fmt='none', capsize=3)
            ax2.set_ylabel('completion rate %')

            plt.title(f'Shutdown Time vs. # Instances ({repeats_per_count} repeats)')
            plt.show()

                
    #file not found error
    except FileNotFoundError:
        print(f"File {file_name} not found")
    #json decoder error
    except json.JSONDecodeError:
        print(f"Error: could not decode json file")
    #general error, display it
    except Exception as e:
        print(f"An error has occured: {e}")


if __name__ == "__main__":
    main()